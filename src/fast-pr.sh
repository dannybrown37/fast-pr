#! /bin/bash


# Opens a pull request from current branch to default branch in repo
# Works with:
#   GitHub
#   Bitbucket (enterprise)
#   ...

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
    commit_message="Commits in pull request:\n"
    for message in "${commit_messages[@]}"; do
        commit_message+="\n$message"
    done
    repo_name=$(basename "$(git rev-parse --show-toplevel)")
    repo_parent=$(git remote -v | grep push | cut -d'/' -f4)

    # Create PR content

    if [ $repo_home = "bitbucket" ]; then

        if [[ -z $BITBUCKET_BASE_URL ]]; then
            json_content="{
                \"title\": \"$pull_request_title\",
                \"description\": \"$commit_message\",
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
            json_content="{
                \"title\": \"$pull_request_title\",
                \"description\": \"$commit_message\",
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

        echo "$json_content" > temp_pr.json

        data_type_header="Content-Type: application/json"
        token=$BITBUCKET_TOKEN

    elif [ $repo_home = "github" ]; then

        json_content="{
            \"title\": \"$pull_request_title\",
            \"body\": \"$commit_message\",
            \"head\": \"$current_branch\",
            \"base\": \"$default_branch\"
        }"
        echo "$json_content" > temp_pr.json

        url="https://api.github.com/repos/$repo_parent/$repo_name/pulls"

        data_type_header="Accept: application/vnd.github.v3+json"
        token=$GITHUB_TOKEN

    fi

    response=$(
        curl -X POST \
        -H "Authorization: Bearer $token" \
        -H "$data_type_header" \
        -d @temp_pr.json \
        -s \
        "$url"
    )

    echo $response

    rm -f temp_pr.json
    if [ $repo_home = "bitbucket" ]; then
        pr_url=$(echo "$response" | jq -r '.links.html.href')
    elif [ $repo_home = "github" ]; then
        pr_url=$(echo "$response" | jq -r '.html_url')
    fi

    echo "Opening: $pr_url"

    # get open browser command
    case $( uname -s ) in
    Darwin)   open='open';;
    MINGW*)   open='start';;
    MSYS*)    open='start';;
    CYGWIN*)  open='cygstart';;
    *)        # Try to detect WSL (Windows Subsystem for Linux)
        if uname -r | grep -q -i microsoft; then
        open='powershell.exe -NoProfile Start'
        else
        open='xdg-open'
        fi;;
    esac

    ${BROWSER:-$open} "$pr_url"

}

pr
