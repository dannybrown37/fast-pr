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
    else
        echo "Error: Repo's remote URL is not yet supported. Add it or stick with GitHub or Bitbucket."
        git remote -v
        return
    fi

    default_branch=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
    current_branch=$(git branch | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/')

    # Get commit hashes and messages for current branch, construct PR description
    non_current_branches=$(git for-each-ref --format='%(refname)' refs/heads/ | grep -v "refs/heads/$current_branch")
    commit_messages=$(git log $current_branch --oneline --not $non_current_branches)
    readarray -t commit_messages <<< "$commit_messages"
    pr_description="Commits in pull request:\n"
    for message in "${commit_messages[@]}"; do
        pr_description+="  \n  $message"
    done
    repo_name=$(basename "$(git rev-parse --show-toplevel)")
    repo_parent=$(git remote -v | grep push | cut -d'/' -f4)

    # Create PR content

    pull_request_title="$current_branch -> $default_branch"

    if [ $repo_host = "bitbucket" ]; then

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
        token=$BITBUCKET_TOKEN

    elif [ $repo_host = "github" ]; then

        json_content="{
            \"title\": \"$pull_request_title\",
            \"body\": \"$pr_description\",
            \"head\": \"$current_branch\",
            \"base\": \"$default_branch\"
        }"

        url="https://api.github.com/repos/$repo_parent/$repo_name/pulls"

        data_type_header="Accept: application/vnd.github.v3+json"
        token=$GITHUB_TOKEN

    fi

    echo "$json_content" > temp_pr.json

    response=$(
        curl -X POST \
            -H "Authorization: Bearer $token" \
            -H "$data_type_header" \
            -d @temp_pr.json \
            -s \
            "$url"
    )
    rm -f temp_pr.json

    if [ $repo_host = "bitbucket" ]; then

        # In Bitbucket, an existing PR will simply be updated and not error out
        pr_url=$(echo "$response" | jq -r '.links.html.href')

    elif [ $repo_host = "github" ]; then

        # In GitHub, an existing PR will be rejected with an error.
        # Just update the description with a follow-up patch request.
        error_message=$(jq -r '.errors[0].message' <<< "$response")
        if [[ $error_message =~ ^A\ pull\ request\ already\ exists\ for\ ([^:]+):([^\.]+)\. ]]; then
            user_name="${BASH_REMATCH[1]}"
            branch_name="${BASH_REMATCH[2]}"

            json_content="{
                \"body\": \"$pr_description\"
            }"
            echo "$json_content" > temp_patch.json

            pr_url="https://github.com/$user_name/$repo_name/pull/$branch_name/"

            # the web UI URL with branch name will redirect to a URL with the
            # pull-request number, which is what we need for the API URL
            redirected_url=$(curl -Ls -o /dev/null -w %{url_effective} $pr_url)
            pull_number=$(basename $redirected_url)

            api_url="${url}/${pull_number}.patch"

            response=$(
                curl -X PATCH \
                    -H "Authorization: Bearer $token" \
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

pr
