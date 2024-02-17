#! /bin/bash


# Opens a pull request from current branch to default branch in repo


pr() {

    if git remote -v | grep -q "bitbucket"; then
        repo_home="bitbucket"
        if [[ -z $BITBUCKET_TOKEN ]]; then
            echo "Error: You must set your BITBUCKET_TOKEN in the environment:"
            echo "export BITBUCKET_TOKEN=abcd"
            echo "If you are using enterprise Bitbucket, you must also set your BITBUCKET_BASE_URL"
            echo "Hint: The base URL should end with \".com\", the rest will be constructed in-script"
            return
        fi
    elif git remote -v | grep -q "github"; then
        repo_home="github"
        if [[ -z $GITHUB_TOKEN ]]; then
            echo "Error: You must set your GITHUB_TOKEN in the environment"
            return
        fi
    else
        echo "Error: Repo's remote URL is not supported. Add it or stick with GitHub or Bitbucket."
        git remote -v
        return
    fi

    # Get default branch
    default_branch=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')

    # Get current branch
    current_branch=$(git branch | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/')
    pull_request_title="$current_branch -> $default_branch"

    # Get commit messages for each line in branch
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

    if [ $repo_home = "bitbucket" ]; then

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

    elif [ $repo_home = "github" ]; then

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

    if [ $repo_home = "bitbucket" ]; then

        # In Bitbucket, an existing PR will simply be updated and not error out
        pr_url=$(echo "$response" | jq -r '.links.html.href')

    elif [ $repo_home = "github" ]; then

        # In GitHub, an existing PR will be rejected with an error.
        # Just update the description with a follow-up patch request.
        error_message=$(jq -r '.errors[0].message' <<< "$response")
        if [[ $error_message =~ ^A\ pull\ request\ already\ exists\ for\ ([^:]+):([^\.]+)\. ]]; then
            user_name="${BASH_REMATCH[1]}"
            branch_name="${BASH_REMATCH[2]}"
            echo "This pull request already exists!"
            json_content="{
                \"body\": \"$pr_description\"
            }"
            echo "$json_content" > temp_patch.json

            pr_url="https://github.com/$user_name/$repo_name/pull/$branch_name/"

            curl -X PATCH \
                -H "Authorization: Bearer $token" \
                -H "$data_type_header" \
                -d @temp_patch.json \
                "$pr_url"

            rm -f temp_patch.json
        else
            echo "PR opened successfully!"
            pr_url=$(echo "$response" | jq -r '.html_url')
        fi
    fi

    echo "Opening web browser to PR URL: $pr_url"

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
