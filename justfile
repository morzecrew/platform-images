set quiet
set shell := ["bash", "-cu"]

# ----------------------- #
# Paths / constants

_reg := "ghcr.io"
_owner := "morzecrew"

# ----------------------- #

# Login to the registry.
_login:
    echo $(gh auth token) | docker login {{ _reg }} -u dummy --password-stdin


# ----------------------- #

# Build a specific version of the image.
[arg("target", long, short="t", help="Target image directory")]
[arg("version", long, short="v", help="Target version")]
[arg("push", long, help="Push the image to the registry", value="true")]
build target="" version="" push="false":
    cd images/{{ target }} && \
    docker build -t {{ _reg }}/{{ _owner }}/{{ target }}:{{ version }} -f {{ version }}/Dockerfile .

    if {{ push }}; then \
        just push -t {{ target }} -v {{ version }}; \
    fi


# Push a specific version of the image.
[arg("target", long, short="t", help="Target image directory")]
[arg("version", long, short="v", help="Target version")]
push target="" version="": _login
    docker push {{ _reg }}/{{ _owner }}/{{ target }}:{{ version }}