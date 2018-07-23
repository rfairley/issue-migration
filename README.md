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
- original posting time of issue and comments
- one assignee only, not multiple
- labels attached to the migrated issues

See https://github.com/rfairley/issue-migration/issues/2  for an example of a migrated issue.

# Post-migration manual fixups

- Delete unneeded labels
- Fix label colors and descriptions (or else create the labels beforehand)
- Update bug references to point to the corresponding newly-created issues,
  or to point back to the source repo when they were originally written in
  the short `#1234` syntax
- Delete bottom-quoted text from email replies (since GitHub doesn't know to
  fold it after migration)
