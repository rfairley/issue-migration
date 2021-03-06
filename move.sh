#!/bin/bash

set -e

# Migrate issues and comments from one repository to another.
# Adapted from https://github.com/crawford/issue-mover

# Instructions:
# 1) make sure this script is being run in a new directory (running it in the repo is good).
# 2) set the .*_OWNER and .*_REPO variables (see indicated below)
# 3) set the AUTHORIZATION_TOKEN to access the GitHub API. A Personal Access Token from GitHub will allow a rate limit of 5000
#    requests per hour, which should be enough for the migration.
#    The associated account must have write access to the source repo and
#    admin access to the destination repo.
# 4) MIGRATE_LABEL - set to the label indicating which issues to move (see indicated below)
# 5) DEST_LABEL - set to a label that corresponds with your DESTINATION_REPO (see indicated below)

# Migration criteria:
# Only issues that have both MIGRATE_LABEL AND DEST_LABEL will be migrated.
# Pull requests will not be migrated.
# In the example in https://github.com/rfairley/issue-migration/issues/2, these labels are
# "component/test" and "kind/otherlabel" respectively (see the now closed issues).

# Testing/Dry run:
# To test that this works the way it is intended, the POST and PATCH
# requests can be commented out (see two comments near end of this file). This will
# be a dry run that doesn't affect the SOURCE_REPO - only the DESTINATION_REPO.

SOURCE_OWNER= 		# <-- coreos
DESTINATION_OWNER=	# <-- coreos
SOURCE_REPO= 		# <-- bugs
DESTINATION_REPO= 	# <-- ignition or coreos-metadata

AUTHORIZATION_TOKEN= 	# Comments and issues are published by whichever acccount owns this token.
			#   Should be a token associated with coreosbot.

MIGRATE_LABEL= 		# <-- "needs/migration"
DEST_LABEL= 		# <-- "component/ignition" or "component/coreos-metadata"

ISSUE_NUMBERS_TO_MIGRATE=issue_numbers.txt # Doesn't matter the name of this file, it gets created and deleted while script runs.

echo "Note: if errors are given, make sure environment variables are set!"
echo "Note: if no issues to be moved are found, an error will result."


escape() {
	sed \
		--expression 's/\\/\\\\/g' \
		--expression 's/\t/\\t/g' \
		--expression 's/\r//g' \
		--expression 's/"/\\"/g' \
		<<< "${1}" | \
		sed --expression ':a;N;$!ba;s/\n/\\n/g'
}

raw_issues=$(curl \
	--silent \
	--request GET \
	--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
	--header "Accept: application/vnd.github.golden-comet-preview+json" \
	--url "https://api.github.com/repos/${SOURCE_OWNER}/${SOURCE_REPO}/issues?per_page=100&labels=$MIGRATE_LABEL,$DEST_LABEL")

[ -e $ISSUE_NUMBERS_TO_MIGRATE ] && rm $ISSUE_NUMBERS_TO_MIGRATE

issue_count=$(jq "length" --raw-output <<< ${raw_issues})

echo "Found ${issue_count} issues total"

# Generate a list of issues to migrate based on matching label.
for i in $(seq 0 $((${issue_count} - 1))); do
	# If the issue is a pull request, then don't migrate it.
	if grep --invert-match null <<< $(jq ".[$i].pull_request" <<< ${raw_issues}) > /dev/null; then
		continue
	fi
	
	issue_labels=$(jq ".[$i].labels" --raw-output <<< ${raw_issues})
	labels_length=$(jq "length" --raw-output <<< ${issue_labels})
	has_migrate_label="false"
	has_dest_label="false"
	for j in $(seq 0 $((${labels_length} - 1))); do
		# Check for having the migrate indicator label and the destination label.
		if [ "$(jq ".[$j].name" --raw-output <<< ${issue_labels})" == "${MIGRATE_LABEL}" ]; then
			has_migrate_label="true"
		fi
		if [ "$(jq ".[$j].name" --raw-output <<< ${issue_labels})" == "${DEST_LABEL}" ]; then
			has_dest_label="true"
		fi
	done

	if [ $has_migrate_label = "true" ] && [ $has_dest_label = "true" ]; then
		echo "$(jq ".[$i].number" --raw-output <<< ${raw_issues})" >> issue_numbers_raw
	fi
done

tac issue_numbers_raw > $ISSUE_NUMBERS_TO_MIGRATE
[ -e issue_numbers_raw ] && rm issue_numbers_raw

echo "Migrating the following issue numbers"
cat $ISSUE_NUMBERS_TO_MIGRATE

## ---- Migration begins now

echo "Starting migration..."

# Migrate the listed issues.
while read issue_number; do

	raw_issue=$(curl \
		--silent \
		--request GET \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		"https://api.github.com/repos/${SOURCE_OWNER}/${SOURCE_REPO}/issues/${issue_number}")

	echo "Processing #$(jq ".number" <<< ${raw_issue}): $(jq ".title" <<< ${raw_issue})"

	issue_body=$(cat <<-EOF
	**Issue by @$(jq ".user.login" --raw-output <<< ${raw_issue})**
	***
	$(jq ".body" --raw-output <<< ${raw_issue})
	EOF
	)

	raw_comments=$(curl \
		--silent \
		--request GET \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url $(jq ".comments_url" --raw-output <<< ${raw_issue})
	)

	comment_count=$(jq "length" --raw-output <<< ${raw_comments})

	comments="[]"
	for i in $(seq 0 $((${comment_count} - 1))); do
		comment_body=$(cat <<-EOF
		**Comment by @$(jq ".[${i}].user.login" --raw-output <<< ${raw_comments})**
		***
		$(jq ".[${i}].body" --raw-output<<< ${raw_comments})
		EOF
		)
		created_at=$(jq ".[${i}].created_at" <<< ${raw_comments})
		comments=$(jq ". + [{created_at: ${created_at}, body: \"$(escape "${comment_body}")\"}]" <<< ${comments})
	done

	data="{
		\"issue\": {
			\"title\": $(jq ".title" <<< ${raw_issue}),
			\"body\": \"$(escape "${issue_body}")\",
			\"created_at\": $(jq ".created_at" <<< ${raw_issue}),
			\"updated_at\": $(jq ".updated_at" <<< ${raw_issue}),
			\"closed\": $(jq ".closed // false" <<< ${raw_issue}),
			\"labels\": $(jq "[.labels[].name]" <<< ${raw_issue}),
			\"assignee\": $(jq ".assignee.login" <<< ${raw_issue})
		},
		\"comments\": ${comments}
	}"

	result=$(curl \
		--silent \
		--request POST \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url "https://api.github.com/repos/${DESTINATION_OWNER}/${DESTINATION_REPO}/import/issues" \
		--data "@-" <<< "${data}")

	status_url=$(jq ".url" --raw-output <<< ${result})
	stat=""
	while [ 1 ]; do
		echo "Waiting for import"
		stat=$(curl \
			--silent \
			--request GET \
			--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
			--header "Accept: application/vnd.github.golden-comet-preview+json" \
			--url ${status_url})

		if grep imported <<< $(jq ".status" <<< ${stat}) > /dev/null; then
			break
		fi

		sleep 1
	done

	raw_issue_dest=$(curl \
		--silent \
		--request GET \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url $(jq ".issue_url" --raw-output <<< ${stat}))

	# Comment this out for a dry run.
	curl \
		--silent \
		--request POST \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url $(jq ".comments_url" --raw-output <<< ${raw_issue}) \
		--data "{\"body\": \"Moved to $(jq ".html_url" --raw-output <<< ${raw_issue_dest}).\"}"

	# Comment this out for a dry run.
	curl \
		--silent \
		--request PATCH \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url $(jq ".url" --raw-output <<< ${raw_issue}) \
		--data '{"state": "closed"}'

done < <(cat $ISSUE_NUMBERS_TO_MIGRATE)
