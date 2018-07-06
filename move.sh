#!/bin/bash

set -e

# Migrate issues and comments from one repository to another.
# Adapted from https://github.com/crawford/issue-mover

# Instructions:
# 1) create a new directory to run this script in
# 2) set the .*_OWNER and .*_REPO variables.
# 3) set your AUTHORIZATION_TOKEN to access the GitHub API
# 4) MIGRATE_LABEL - set to the label indicating which issues to move
# 5) DEST_LABEL - set to a label that corresponds with your DESTINATION_REPO - to ensure only labels with this set are moved to DESTINATION_REPO
# 6) ISSUE_NUMBERS_TO_MIGRATE is a file that will be created to store the list of issue numbers to migrate, then read from during migration

SOURCE_OWNER=rfairley
DESTINATION_OWNER=rfairley
SOURCE_REPO=migration-test-start
DESTINATION_REPO=migration-test-finish

AUTHORIZATION_TOKEN=

MIGRATE_LABEL="migrate/me"
DEST_LABEL="desination/indicator"
ISSUE_NUMBERS_TO_MIGRATE=issue_numbers.txt

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
	--url "https://api.github.com/repos/${SOURCE_OWNER}/${SOURCE_REPO}/issues")

echo $raw_issues > raw

[ -e $ISSUE_NUMBERS_TO_MIGRATE ] && rm $ISSUE_NUMBERS_TO_MIGRATE

issue_count=$(jq "length" --raw-output <<< ${raw_issues})

echo "Found ${issue_count} issues total"

# Generate a list of issues to migrate based on matching label.
for i in $(seq 0 $((${issue_count} - 1))); do
	issue_labels=$(jq ".[$i].labels" --raw-output <<< ${raw_issues})
	labels_length=$(jq "length" --raw-output <<< ${issue_labels})
	has_migrate_label="false"
	has_dest_label="false"
	for j in $(seq 0 $((${labels_length} - 1))); do
		# If the issue is a pull request, then don't migrate it.
		if grep --invert-match null <<< $(jq ".[${i}].pull_request" <<< ${raw_issues}) > /dev/null; then
			continue
		fi

		# Check for having the migrate indicator label and the destination label.
		if [ "$(jq ".[$j].name" --raw-output <<< ${issue_labels})" == "${MIGRATE_LABEL}" ]; then
			has_migrate_label="true"
		fi

		if [ "$(jq ".[$j].name" --raw-output <<< ${issue_labels})" == "${DEST_LABEL}" ]; then
			has_dest_label="true"
		fi
	done

	if [ $has_migrate_label = "true" ] && [ $has_dest_label = "true" ]; then
		echo "here"
		echo "$(jq ".[$i].number" --raw-output <<< ${raw_issues})" >> issue_numbers_raw
	fi
done

tac issue_numbers_raw > $ISSUE_NUMBERS_TO_MIGRATE
[ -e issue_numbers_raw ] && rm issue_numbers_raw

echo "Migrating the following issue numbers"
cat $ISSUE_NUMBERS_TO_MIGRATE

## ---- Below this can be a separate script

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

	#echo $raw_comments

	comment_count=$(jq "length" --raw-output <<< ${raw_comments})

	echo $comment_count
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

	curl \
		--silent \
		--request POST \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url $(jq ".comments_url" --raw-output <<< ${raw_issue}) \
		--data "{\"body\": \"Moved to $(jq ".html_url" --raw-output <<< ${raw_issue_dest})\"}"

	curl \
		--silent \
		--request PATCH \
		--header "Authorization: token ${AUTHORIZATION_TOKEN}" \
		--header "Accept: application/vnd.github.golden-comet-preview+json" \
		--url $(jq ".url" --raw-output <<< ${raw_issue}) \
		--data '{"state": "closed"}'

done < <(cat $ISSUE_NUMBERS_TO_MIGRATE)
