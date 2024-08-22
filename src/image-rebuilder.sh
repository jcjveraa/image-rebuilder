#!/bin/bash
#    image-rebuilder - a shell script to keep your Dockerfile-based images up to date
#    Copyright (C) 2024  Jelle Veraa
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.


## This scipt rebuilds a Dockerfile/Containerfile in the currnent folder (it runs the command 'docker build .' or
## 'podman build .' plus setting tags) if any of the base images identified by FROM in the Dockerfile were updated. It
## uses no external dependencies (other than docker or podman of course).

### START CONFIGURING ENVIRONMENT ###

# check if we have docker and/or podman, suppressing 'not found' by redirecting stderr
DOCKER_EXECUTABLE=$(which docker 2>/dev/null)
PODMAN_EXECUTABLE=$(which podman 2>/dev/null)
BUILD_TIME=$(date -u +'%Y-%m-%dT%H.%M.%SZ')

# assume we use docker, set to podman later
DOCKER="DOCKER"
PODMAN="PODMAN"
MODE=$DOCKER

while getopts e:pdf:c:rt: flag
do
    case "${flag}" in
        e)
          echo "Using executable ${OPTARG}"
          if [[ "${OPTARG}" == *podman* ]]; then
            MODE=$PODMAN
            PODMAN_EXECUTABLE=${OPTARG}
          elif [[ "${OPTARG}" == *docker* ]]; then
            DOCKER_EXECUTABLE=${OPTARG}
          else
            echo "Ony docker and podman are supported. If your executable does not have the specific name containing"\
            "the string 'docker' or 'podman', please create an alias (symlink/shortcut) to the executable and use that."
            exit 39
          fi
          EXECUTABLE=${OPTARG};;
        p)
          if [ -z "$PODMAN_EXECUTABLE" ]; then
            echo "Podman cli executable not found! Try specifying it with the -e flag."
            exit 41
          fi
          echo "Using Podman"
          EXECUTABLE=$PODMAN_EXECUTABLE
          MODE=$PODMAN;;
        d)
          if [ -z "$DOCKER_EXECUTABLE" ]; then
            echo "Docker cli executable not found on path! Try specifying it with the -e flag."
            exit 40
          fi
          echo "Using Docker"
          EXECUTABLE=$DOCKER_EXECUTABLE;;
        r) echo "Forcing rebuild" && FORCE=true;;
        f)
          # The location of the file we want to build. Also sets the context to that path if it isn't set.
          CONTAINERFILE=${OPTARG}
          if [ -z "$CONTEXT" ]; then
            # Assume we want our context to be where the dockerfile is - this strips the last part (filename) off.
            # Will either be ignored or overwritten by the -c option.
            CONTEXT=$(echo -n "${OPTARG}" | sed -E -e "s/\/([^/]*?)$//")
            echo "Context set to $CONTEXT"
          fi
          ;;
        c)
          # the context parameter of the build command (the 'current working directory' used by the build command)
          # defaults to '.', the directory of the
          CONTEXT=${OPTARG};;
        t)
          # split a comma seperated list in to a list of '--tag $tag'
          # a special tag _timestamp will add the current timestamp
          TAGS=$(echo -n "${OPTARG}" | tr "," " ")
          ;;
        ?) echo "Argument not recognized, exiting!" && exit 42
    esac
done

# set default context
if [ -z "$CONTEXT" ]; then
  echo "Using default context ."
  CONTEXT="."
fi

if [ $MODE = $PODMAN ]; then
  echo "!! Warning! As is Podman is mostly untested as development is happening with Docker !!"
fi

## get the desired image name
# remove all flag-options to get the remaining argument which is the image name
shift $((OPTIND - 1))

if [[ -n $1 ]]; then
  TARGET_IMAGE_NAME=$1
else
  echo "No target image name specified! Run with './image-rebuilder.sh [optional flags] my-image-name'"
fi

## Setup the tags for the image

# add default tags if none where specified
if [ -z "$TAGS" ]; then
  echo "Adding default tags '$TARGET_IMAGE_NAME:latest' and the current UTC time '$TARGET_IMAGE_NAME:$BUILD_TIME'." \
      "To suppress the current timestamp, run with the '-t'" \
      " flag, e.g. '-t latest' to only set the 'latest' tag and not the timestamp."
  TAGS="latest _timestamp"
fi

for tag in $TAGS; do
  # to check if the
  image_tag_pattern='^[a-zA-Z\d_][_.a-zA-Z\d\-]{0,127}$'

  # a special tag _timestamp (normally illegal as a tag may not start with an underscore) will add the UTC timestamp to
  # provide a unique tag
  if [ "$tag" = "_timestamp" ]; then
    tag=$BUILD_TIME
  elif [[ ! $tag =~ $image_tag_pattern ]]; then
    echo "Tag $tag does not seem to be a valid image tag due to invalid characters. The image tags need to" \
         "be comma separated and individually match the following regex pattern: $image_tag_pattern"
    exit 38
  fi

  # concat together
  IMAGE_TAGS="$IMAGE_TAGS--tag $TARGET_IMAGE_NAME:$tag "
done


if [ -z "$TARGET_IMAGE_NAME" ]; then
  echo "No target image name specified! Run with './image-rebuilder.sh -n my-image-name' [additional args]"
  exit 89
fi

# if the executable was not specified, then use what we have available
if [ ! -v "$EXECUTABLE" ]; then
  if [ -n "$DOCKER_EXECUTABLE" ]; then
    EXECUTABLE=$DOCKER_EXECUTABLE
    echo "Using docker at $DOCKER_EXECUTABLE"
  elif [ -n "$PODMAN_EXECUTABLE" ]; then
    EXECUTABLE=PODMAN_EXECUTABLE
    MODE=podman
    echo "Using podman at $PODMAN_EXECUTABLE"
  fi
fi

if [ -z "$EXECUTABLE" ]; then
  echo 'No executable was found! Optionally specify one with the -e flag.'
  exit 1
fi

# set the default containerfile-name for docker (Dockerfile) or podman (Containerfile)
if [ $MODE = $DOCKER ]; then  DEFAULT_FILE_NAME="Dockerfile"; else  DEFAULT_FILE_NAME="Containerfile"; fi
# if we don't have a name yet, set it to the default name
if [ -z "$CONTAINERFILE" ]; then CONTAINERFILE=$DEFAULT_FILE_NAME; fi
# check if the file exists
if [ ! -f "$CONTAINERFILE" ]; then
  echo "Dockerfile named [$CONTAINERFILE] not found"
  exit 1
fi

# check if the containerfile has changed
CONTAINER_DIGEST_FILE="$CONTEXT/containerfile-digest.txt"
if [ ! -f "$CONTAINER_DIGEST_FILE" ]; then
  echo "Dockerfile/Containerfile digest file missing, rebuild!"
  REBUILD_REQUIRED=true
else
  CURRENT_FILE_SUM=$(sha1sum "$CONTAINERFILE")
  CONTAINER_DIGEST_FILE_VALUE=$(cat "$CONTAINER_DIGEST_FILE")
  if [ "$CONTAINER_DIGEST_FILE_VALUE" != "$CURRENT_FILE_SUM" ]; then
    echo "Dockerfile/Containerfile changed, rebuild!"
    REBUILD_REQUIRED=true
    echo "$CURRENT_FILE_SUM" > "$CONTAINER_DIGEST_FILE"
  fi
fi

# make sure the container digest file gets created
if [ ! -f "$CONTAINER_DIGEST_FILE" ]; then echo "$CURRENT_FILE_SUM" > "$CONTAINER_DIGEST_FILE"; fi

### START THE REAL WORK ###

## Find the images that are in the container file
# grep - Get all lines starting with "FROM " -> these are our base images (note: there should be no characters in front of FROM)
# sed - then strip the FROM and any whitespace to get the base image name, surrounded by quotes.
# paste - join by spaces instead of newlines
BASE_IMAGES=$(grep "^FROM" "$CONTAINERFILE" | sed -e "s/FROM[[:space:]]*\(.*\)/\1/" | paste -s -d ' ')
echo "Found base images [$BASE_IMAGES] in $CONTAINERFILE"

# Pull the image such that we get the latest version. This script relies on the docker/podman pull command echoing a digest
for BASE_IMAGE in $BASE_IMAGES
do
  # skip reserved name scratch if present
  if [ "$BASE_IMAGE" = "scratch" ]; then
    continue
  fi

  echo "Pulling $BASE_IMAGE from the registry and checking digest ..."
  if [ $MODE = $DOCKER ]; then
    # The docker pull command should output a line such as
    # Digest: sha256:2bafb1fb2d6489bccadc1b7c172937e9b56a888ed77e625a4ebe59a6b038221e
    base_image_digest=$("$EXECUTABLE" pull "$BASE_IMAGE" | grep Digest: )
  else
    # The podman pull command outputs the hash as the last line of its output such as
    # bafb1fb2d6489bccadc1b7c172937e9b56a888ed77e625a4ebe59a6b038221e
    base_image_digest=$("$EXECUTABLE" pull "$BASE_IMAGE" | tail -1 )
  fi

  ## Build the name of the file in which we store the digest. This file will be created on the first run
  # echo -n - skip the newline at the end
  # tr - replace anything which is NOT an alphanumeric or literal dot character
  BUILD_DIGEST_FILE=$(echo -n "$BASE_IMAGE-digest.txt" | tr -c -s '[:alnum:].' '_')

  # Check if we have a previous digest stored in our BUILD_DIGEST_FILE (if it exists)
  if [ -f "$BUILD_DIGEST_FILE" ]; then
    last_build_base_image_digest=$(cat "$BUILD_DIGEST_FILE")
  fi

  ## Check if the digests match, if not we have a new base image!
  if [ "$base_image_digest" != "$last_build_base_image_digest" ]; then
    echo "New image found for base image $BASE_IMAGE!"
    echo "$base_image_digest" > "$BUILD_DIGEST_FILE"
    REBUILD_REQUIRED=true
    # do NOT break here, as we need to store all different base image digests to avoid rebuilds if more than 1 image changes
  else
    echo "Digest for $BASE_IMAGE stored in $BUILD_DIGEST_FILE matches current digest in the registry."
  fi
done

# check if we need to do a rebuild
if [ "$REBUILD_REQUIRED" ] || [ "$FORCE" ]; then DO_BUILD=true; else DO_BUILD=false; fi

# if we have any new base image, rebuild our Dockerfile and tag it as 'latest' and with the current timestamp
# the below relies on the podman and docker syntax to be equal, which it is per august 2024
if [ "$DO_BUILD" = true ]; then
  echo "Building [$CONTAINERFILE] using [$EXECUTABLE], with context directory [$CONTEXT] and tagging with tags [$IMAGE_TAGS]."
  # print the command to stdout for transparency
  set -x
  # Add double quotes in case (like often on windows) the executable is in 'Program Files' with  a space, which will trip up the command line
  eval "\"$EXECUTABLE\"" build "$IMAGE_TAGS" --label "built-with-image-rebuilder=https://github.com/jcjveraa/image-rebuilder" -f "$CONTAINERFILE" "$CONTEXT"
  set +x
else
  echo 'The image is up to date, skipping rebuild.'
fi

if [ "$FORCE" ]; then
  echo "Note: the rebuild was forced with the -r flag chiefly meant for testing! This is not a typical usage of" \
        "image-rebuild.sh as a simpler script that simply 'always rebuilds' would suffice."
fi
