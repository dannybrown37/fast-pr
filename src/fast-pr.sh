#! /bin/bash


# Opens a pull request from current branch to default branch in repo

pr() {

    if git remote -v | grep -q "bitbucket"; then
        repo_host="bitbucket"
        if [[ -z $BITBUCKET_TOKEN ]]; then
            echo "Error: You must set your BITBUCKET_TOKEN in the environment:"
            echo "export BITBUCKET_TOKEN=abcd"
            echo "If you are using enterprise Bitbucket, you must also set your BITBUCKET_BASE_URL"
            echo "Hint: The base URL should end with \".com\", the rest will be constructed in-script"
            return
        fi
    elif git remote -v | grep -q "github"; then
        repo_host="github"
        if [[ -z $GITHUB_TOKEN ]]; then
            echo "Error: You must set your GITHUB_TOKEN in the environment"
            echo "export GITHUB_TOKEN=efgh"
            return
        fi
    elif git remote -v | grep -q "gitlab"; then
        repo_host="gitlab"
        if [[ -z $GITLAB_TOKEN ]]; then
            echo "Error: You must set your GITLAB_TOKEN in the environment"
            echo "export GITLAB_TOKEN=ijkl"
            return
        fi
    else
        echo "Error: Repo's remote URL is not yet supported. Add it or stick with GitHub, GitLab, or Bitbucket."
        git remote -v
        return
    fi

    default_branch=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
    current_branch=$(git branch | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/')

    # Get commit hashes and messages for current branch, construct PR description
    non_current_branches=$(git for-each-ref --format='%(refname)' refs/heads/ | grep -v "refs/heads/$current_branch")
    commit_messages=$(git log "$current_branch" --oneline --not "$non_current_branches")
    readarray -t commit_messages <<< "$commit_messages"
    pr_description="Commits in pull request:\n"
    for message in "${commit_messages[@]}"; do
        pr_description+="  \n  $message"
    done
    repo_name=$(basename "$(git rev-parse --show-toplevel)")

    # Get repo_parent (i.e., user or project); works with HTTPS and SSH
    remote_url=$(git remote get-url origin)
    if [[ "$remote_url" == https://* ]]; then
        repo_parent=$(echo "$remote_url" | cut -d'/' -f4)
    elif [[ "$remote_url" == git@* ]]; then
        repo_parent=$(echo "$remote_url" | cut -d':' -f2 | cut -d'/' -f1)
    elif [[ "$remote_url" == ssh://* ]]; then
        repo_parent=$(echo "$remote_url" | cut -d'/' -f4)
    else
        echo -e "ERROR: no username/project/repo owner detected in URL:\n\t$remote_url"
        echo "It probably has an unexpected format, please raise a GitHub issue."
        return
    fi

    pull_request_title="$current_branch -> $default_branch"

    if [ "$repo_host" = "bitbucket" ]; then

        if [[ -z $BITBUCKET_BASE_URL ]]; then
            # Personal/cloud Bitbucket
            json_content="{
                \"title\": \"$pull_request_title\",
                \"description\": \"$pr_description\",
                \"source\": {
                    \"branch\": {
                        \"name\": \"$current_branch\"
                    }
                },
                \"destination\": {
                    \"branch\": {
                        \"name\": \"$default_branch\"
                    }
                }
            }"
            url="https://api.bitbucket.org/2.0/repositories/$repo_parent/$repo_name/pullrequests"
        else
            # Enterprise Bitbucket
            json_content="{
                \"title\": \"$pull_request_title\",
                \"description\": \"$pr_description\",
                \"fromRef\": {
                    \"id\": \"refs/heads/$current_branch\",
                    \"repository\": \"$repo_name\",
                    \"project\": {\"key\": \"$repo_parent\"}
                },
                \"toRef\": {
                    \"id\": \"refs/heads/$default_branch\",
                    \"repository\": \"$repo_name\",
                    \"project\": {\"key\": \"$repo_parent\"}
                }
            }"
            url="$BITBUCKET_BASE_URL/rest/api/1.0/projects/$repo_parent/repos/$repo_name/pull-requests"
        fi

        data_type_header="Content-Type: application/json"
        token_header="Authorization: Bearer $BITBUCKET_TOKEN"

    elif [ "$repo_host" = "github" ]; then

        json_content="{
            \"title\": \"$pull_request_title\",
            \"body\": \"$pr_description\",
            \"head\": \"$current_branch\",
            \"base\": \"$default_branch\"
        }"

        url="https://api.github.com/repos/$repo_parent/$repo_name/pulls"

        data_type_header="Accept: application/vnd.github.v3+json"
        token_header="Authorization: Bearer $GITHUB_TOKEN"

    elif [ "$repo_host" = "gitlab" ]; then

        json_content="{
            \"title\": \"$pull_request_title\",
            \"description\": \"$pr_description\",
            \"source_branch\": \"$current_branch\",
            \"target_branch\": \"$default_branch\"
        }"

        url="https://gitlab.com/api/v4/projects/$repo_parent%2F$repo_name/merge_requests"

        data_type_header="Content-Type: application/json"
        token_header="Private-Token: $GITLAB_TOKEN"
    fi

    echo "$json_content" > temp_pr.json

    response=$(
        curl -X POST \
            -H "$token_header" \
            -H "$data_type_header" \
            -d @temp_pr.json \
            -s \
            "$url"
    )

    if [[ $response == *"\"errors\""* ]]; then
        echo "fast-pr was unsuccessful. Error(s) encountered with API call:"
        echo "$response" | jq
        return
    fi

    rm -f temp_pr.json

    if [ "$repo_host" = "bitbucket" ]; then

        # In enterprise Bitbucket, duplicate PRs will error and can't be updated via API
        error_message=$(jq -r '.errors[0].message' <<< "$response")
        duplicate="Only one pull request may be open for a given source and target branch"
        if [[ $error_message == "$duplicate" ]]; then
            echo "$duplicate"
            echo "Bitbucket API v1 does not support updating pull request descriptions."
            echo "Please update manually or delete the PR and reopen."
            pr_url=$(jq '.errors[0].existingPullRequest.links.self[0].href' <<< "$response")
        else
            if [[ -z $BITBUCKET_BASE_URL ]]; then
                # In personal/cloud Bitbucket, an existing PR will be updated and not error out
                pr_url=$(echo "$response" | jq -r '.links.html.href')
            else
                # enterprise Bitbucket path is different on success
                pr_url=$(echo "$response" | jq -r '.links.self[0].href')
            fi
        fi



    elif [ "$repo_host" = "gitlab" ]; then

        error_message=$(jq -r '.message[0]' <<< "$response")
        if [[ $error_message =~ ^Another\ open\ merge\ request\ already\ exists\ for\ this\ source\ branch:\ ([^\.]+) ]]; then
            existing_mr_number=${BASH_REMATCH[1]#\!}

            gitlab_patch_json_content="{
                \"description\": \"$pr_description\"
            }"
            echo "$gitlab_patch_json_content" > temp_patch.json

            # Construct the API URL for the update
            api_url="https://gitlab.com/api/v4/projects/$repo_parent%2F$repo_name/merge_requests/$existing_mr_number"

            # Send the PUT request to update the description
            response=$(
                curl -X PUT \
                    -H "$token_header" \
                    -H "$data_type_header" \
                    -d @temp_patch.json \
                    -s \
                    "$api_url"
            )

            rm -f temp_patch.json

            pr_url=$(echo "$response" | jq -r '.web_url')
            echo "This merge request already exists, but the description has been updated."


        else
            echo "Successfully opened merge request!"
            pr_url=$(echo "$response" | jq -r '.web_url')
        fi

    elif [ "$repo_host" = "github" ]; then

        # In GitHub, an existing PR will be rejected with an error.
        # Just update the description with a follow-up patch request.
        error_message=$(jq -r '.errors[0].message' <<< "$response")
        if [[ $error_message =~ ^A\ pull\ request\ already\ exists\ for\ ([^:]+):([^\.]+)\. ]]; then
            user_name="${BASH_REMATCH[1]}"
            branch_name="${BASH_REMATCH[2]}"

            github_patch_json_content="{
                \"body\": \"$pr_description\"
            }"
            echo "$github_patch_json_content" > temp_patch.json

            pr_url="https://github.com/$user_name/$repo_name/pull/$branch_name/"

            # the web UI URL with branch name will redirect to a URL with the
            # pull-request number, which is what we need for the API URL
            redirected_url=$(curl -Ls -o /dev/null -w "%{url_effective}" "$pr_url")
            pull_number=$(basename "$redirected_url")

            api_url="${url}/${pull_number}.patch"

            response=$(
                curl -X PATCH \
                    -H "$token_header" \
                    -H "$data_type_header" \
                    -d @temp_patch.json \
                    -s \
                    "$api_url"
            )

            rm -f temp_patch.json
            echo "This PR already exists, but the description has been updated."
        else
            echo "PR opened successfully!"
            pr_url=$(echo "$response" | jq -r '.html_url')
        fi
    fi

    echo -e "\nOpening web browser to PR URL:\n$pr_url"

    # get open browser command
    case $(uname -s) in
    Darwin)   open='open';;
    MINGW*)   open='start';;
    MSYS*)    open='start';;
    CYGWIN*)  open='cygstart';;
    *)  # Try to detect WSL (Windows Subsystem for Linux)
        if uname -r | grep -q -i microsoft; then
            open='powershell.exe -NoProfile Start'
        else
            open='xdg-open'
        fi;;
    esac

    ${BROWSER:-$open} "$pr_url"

}

for arg in "$@"; do
    if [ "$arg" == "--version" ] || [ "$arg" == "-v" ]
    then
        version=$(jq -r .version "$(npm list -g | head -1)"/node_modules/fast-pr/package.json)
        echo "fast-pr v$version"
        latest=$(curl -s "https://registry.npmjs.org/fast-pr" | jq -r '.["dist-tags"].latest')
        if [ "$version" != "$latest" ]; then
            echo "fast-pr v$latest is available"
            echo "Update with \"sudo npm update --global fast-pr\""
        fi
        re turn
    fi
done


pr
