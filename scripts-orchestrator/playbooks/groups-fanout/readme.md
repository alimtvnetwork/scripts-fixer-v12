# groups-fanout

Apply a single `groups.json` bundle across every host in a target group.
Mirrors `users-fanout` but for local groups.

## Run

```bash
./run.sh playbook groups-fanout \
    --group production \
    --with-file GROUPS_JSON_B64=/path/to/groups.json \
    --with-env  USERMGMT_DIR=/opt/68-user-mgmt
```

Wraps `scripts-linux/68-user-mgmt/add-group-from-json.sh` on each host.
