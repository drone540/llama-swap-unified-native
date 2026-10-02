#!/usr/bin/env bash

repos=(
    "llama|ggml-org/llama.cpp"
    "ik-llama|Thireus/ik_llama.cpp"
    "sd|leejet/stable-diffusion.cpp"
    "whisper|ggml-org/whisper.cpp"
    "acestep|ServeurpersoCom/acestep.cpp"
    "audio|0xShug0/audio.cpp"
    "crispasr|CrispStrobe/CrispASR"
    "kokoro|remsky/Kokoro-FastAPI"
    "llama-swap|mostlygeek/llama-swap"
)

for entry in "${repos[@]}"; do
    name="${entry%%|*}"
    repo="${entry#*|}"

    echo
    echo "========================================"
    echo "$name"
    echo "========================================"

    response="$(
        curl -fsSL \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/$repo/releases?per_page=5"
    )" || {
        echo "ERROR: Could not query GitHub"
        continue
    }

    # Find the newest non-draft release containing
    # at least one downloadable archive.
    release="$(
        jq -c '
            [
                .[]
                | select(.draft == false)
                | select(
                    any(
                        .assets[];
                        (.name | test(
                            "\\.(zip|tar\\.gz|tgz|tar\\.xz|tar\\.bz2|tar\\.zst)$";
                            "i"
                        ))
                    )
                )
            ]
            | .[0] // empty
        ' <<< "$response"
    )"

    if [[ -z "$release" ]]; then
        echo "No release containing downloadable archives found."
        continue
    fi

    tag="$(jq -r '.tag_name' <<< "$release")"
    release_name="$(jq -r '.name // empty' <<< "$release")"
    date="$(jq -r '.published_at // .created_at // empty' <<< "$release")"

    echo "Release: $tag"

    if [[ -n "$release_name" && "$release_name" != "$tag" ]]; then
        echo "Name:    $release_name"
    fi

    echo "Date:    $date"
    echo

    # List only archive files from this release.
    jq -r '
        .assets[]
        | select(
            .name | test(
                "\\.(zip|tar\\.gz|tgz|tar\\.xz|tar\\.bz2|tar\\.zst)$";
                "i"
            )
        )
        | .browser_download_url
    ' <<< "$release"
done