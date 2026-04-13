# sdcli-autokit

`sdcli-autokit` is a Podman-based toolkit container for running SQL Server to Oracle migration workflows with Oracle SQL Developer CLI (`sdcli`).

## Quick start

### 1. Configure `.env`

```bash
IMAGE_NAME=sdcli-autokit:latest
VOLUME_NAME=sdcli-autokit_volume
CONTAINER_NAME=sdcli-autokit
CONTAINER_HOSTNAME=sdcli-autokit

APP_USER=sduser
APP_GROUP=sduser
APP_UID=1000
APP_GID=1000

HOME_DIR=/home/sduser
APP_HOME=/home/sduser/sdcli-autokit
TOOL_DATA=/u01/data/sdcli-autokit
TOOL_LOG=/u01/log

SD_HOME=/u01/app/sqldeveloper
SD_RPM_MOUNT=/mnt/sqldeveloper/sqldeveloper.rpm
```

### 2. Build

```bash
./build.sh
```

### 3. First run

Provide the SQL Developer RPM path at runtime:

```bash
SD_RPM_PATH=/path/to/sqldeveloper-24.3.1-347.1826.noarch.rpm ./run.sh
```

This will:

- check whether SQL Developer is already installed in the volume
- install it if needed
- create and start the container

### 4. Start and stop later

Start an existing stopped container:

```bash
./start.sh
```

Stop the running container:

```bash
./stop.sh
```

## Useful commands

Open a shell in the container:

```bash
podman exec -it sdcli-autokit bash
```

Check the main tools:

```bash
sdcli --help
sqlcmd -?
bcp -v
jq --version
```

Check container status:

```bash
podman ps -a
```

Check images and volumes:

```bash
podman images
podman volume ls
```

## Notes

- The runtime volume is mounted to `/u01`.
- SQL Developer is installed into `/u01/app/sqldeveloper`.
- `run.sh` is for first bring-up or re-create scenarios.
- `start.sh` and `stop.sh` are for normal day-to-day operations.
