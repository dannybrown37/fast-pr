# Fast PR

Do you ever just want to get your build started immediately? Want to
worry about descriptions, reviewers, and such at a later time?
`fast-pr` gives you a simple tool to do just this and no more.

## Installation

    sudo npm install --global fast-pr

## Credentials

You'll need to set credentials for whichever git remote(s) your projects use.
You should add personal access tokens for the accounts in question to your
environment like so:

    export GITHUB_TOKEN=<value>
    export BITBUCKET_TOKEN=<value>

If you are using enterprise Bitbucket (i.e., not bitbucket.org), you should
also set your base URL (ending in `.com` or whatever suffix your URL uses).

    export BITBUCKET_BASE_URL=<value>

## Usage

    fast-pr

That's it! Assuming you are in a Git repo, `fast-pr` will:

1. Create a pull request from the current branch to the default branch with:

    a. A title including both branch names
    b. A PR description message that includes one commit hash and message per line.

2. Use your default web browser to open the URL of the newly opened pull request.

## Options

None at this time! The beauty of this project is its simplicity.
Need a quick and basic PR? Just use `fast-pr`.

## Repository Host Compatibility

`fast-pr` at this time works with:

* GitHub (personal)
* Bitbucket (personal & enterprise)
