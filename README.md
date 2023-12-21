# kamailio-docker

[![GitHub Workflow - CI](https://github.com/mailsvb/kamailio-docker/workflows/build/badge.svg)](https://github.com/mailsvb/kamailio-docker/actions?workflow=publish)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/mailsvb/kamailio-docker)](https://github.com/mailsvb/kamailio-docker/releases/latest)
[![Docker Image Size (latest semver)](https://img.shields.io/docker/image-size/mailsvb/kamailio?sort=semver)](https://hub.docker.com/repository/docker/mailsvb/kamailio)

## Requirements
*  docker
*  docker-compose

## Installation instructions
###### start the container
`docker compose up -d`

###### stop the running container
`docker compose stop`

###### start the stopped container
`docker compose start`

###### remove all containers/images
`docker compose down --rmi all`

## Environment variables
* `PUBLIC_IP=1.2.3.4` default=0.0.0.0
* `UDP_PORT` default=5060
* `TCP_PORT` default=5060
* `TLS_PORT` default=5061
