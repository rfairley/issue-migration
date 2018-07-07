# issue-migration

Please see the script `move.sh` for comments indicating how the environment variables should be set.
Then, just run the script from within this repo directory.

```
cd issue-migration
chmod +x ./move.sh
./move.sh
```

On success, messages will be printed to the console as each issue is processed one by one. Takes about 2 seconds per issue.

The script migrates:
- issue title
- issue body (reposted)
- issue comments (reposted)
- one assignee only, not multiple
- labels attached to the migrated issues

See https://github.com/rfairley/migration-test-finish/issues/12 for an example of a migrated issue.
