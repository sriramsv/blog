image := "hugomods/hugo:exts"

# Scaffold a new post (uses archetypes/default.md), e.g. `just new-post my-first-post`
new-post slug:
    docker run --rm -v "$(pwd)":/src -w /src {{image}} new content posts/{{slug}}.md

# Build the site locally (requires hugo installed)
build:
    hugo --minify

# Serve the site locally with drafts (requires hugo installed)
serve:
    hugo server -D

# Build the site in Docker, no local hugo install needed
docker-build:
    docker run --rm -v "$(pwd)":/src -w /src {{image}} --minify

# Serve the site in Docker, no local hugo install needed
docker-serve:
    docker run --rm -v "$(pwd)":/src -w /src -p 1313:1313 {{image}} server -D --bind=0.0.0.0 --baseURL=http://localhost:1313/
