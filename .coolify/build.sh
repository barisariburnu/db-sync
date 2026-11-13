#!/bin/sh
set -eu
compose_file=./.coolify/compose.yaml
build_env=/artifacts/build-time.env
docker compose --project-directory . --env-file "$build_env" -f "$compose_file" build
container=$(docker compose --project-directory . --env-file "$build_env" -f "$compose_file" config | sed -n 's/^    container_name: //p')
project=$(docker compose --project-directory . --env-file "$build_env" -f "$compose_file" config | sed -n 's/^name: //p')
test "$container" = "db-sync-$project"
if docker inspect "$container" >/dev/null 2>&1; then
    actual_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container")
    actual_service=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$container")
    test "$actual_project" = "$project"
    test "$actual_service" = 'db-sync'
    legacy=false
    if ! docker inspect --format '{{json .Config.Entrypoint}}' "$container" | grep -q '/app/.coolify/start.sh'; then
        if test "$(docker inspect --format '{{.State.Running}}' "$container")" = true; then
        process_list=$(docker top "$container" -eo pid,comm)
        unexpected=$(printf '%s\n' "$process_list" | tail -n +2 | awk '$2 != "cron" && $2 != "docker-init" {print $2}')
        if test -n "$unexpected"; then
            echo 'Deployment deferred: the legacy scheduler is running an active job.' >&2
            exit 75
        fi
        fi
        legacy=true
    fi
    # An unlimited graceful stop never escalates to SIGKILL while a data reload is active.
    docker stop --time -1 "$container" >/dev/null
    code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
    if test "$legacy" = true; then
        # An idle legacy cron exits on TERM without a wrapper; active jobs are rejected above.
        test "$code" = 0 || test "$code" = 143
    else
        test "$code" = 0
    fi
fi
