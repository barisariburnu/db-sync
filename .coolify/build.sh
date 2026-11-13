#!/bin/sh
set -eu
compose_file=./.coolify/compose.yaml
build_env=/artifacts/build-time.env
docker compose --env-file "$build_env" -f "$compose_file" build
container=$(docker compose --env-file "$build_env" -f "$compose_file" config | sed -n 's/^    container_name: //p')
project=$(docker compose --env-file "$build_env" -f "$compose_file" config | sed -n 's/^name: //p')
test "$container" = "db-sync-$project"
if docker inspect "$container" >/dev/null 2>&1; then
    actual_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container")
    actual_service=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$container")
    test "$actual_project" = "$project"
    test "$actual_service" = 'db-sync'
    if ! docker inspect --format '{{json .Config.Entrypoint}}' "$container" | grep -q '/app/.coolify/start.sh'; then
        processes=$(docker top "$container" -eo comm | tail -n +2 | wc -l)
        if test "$processes" -gt 1; then
            echo 'Deployment deferred: the legacy scheduler is running an active job.' >&2
            exit 75
        fi
    fi
    # An unlimited graceful stop never escalates to SIGKILL while a data reload is active.
    docker stop --time -1 "$container" >/dev/null
    test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0
fi
