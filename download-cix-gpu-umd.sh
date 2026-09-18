#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${REPO_URL:-https://archive.cixtech.com/debian}
SUITE=${SUITE:-trixie}
COMPONENT=${COMPONENT:-main}
ARCH=${ARCH:-arm64}
PACKAGE=${PACKAGE:-cix-gpu-umd}
OUTPUT_DIR=${OUTPUT_DIR:-dist}

for command in curl gzip awk dpkg sha256sum stat; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

index_url="${REPO_URL%/}/dists/${SUITE}/${COMPONENT}/binary-${ARCH}/Packages.gz"
tmp_index=$(mktemp)
tmp_package=""
trap 'rm -f "$tmp_index" ${tmp_package:+"$tmp_package"}' EXIT

curl --fail --location --retry 3 --retry-delay 2 --silent --show-error \
    "$index_url" -o "$tmp_index"

best_version=""
best_filename=""
best_sha256=""
best_size=""

while IFS=$'\t' read -r version filename sha256 size; do
    [[ -n "$version" && -n "$filename" && -n "$sha256" ]] || continue
    if [[ -z "$best_version" ]] || dpkg --compare-versions "$version" gt "$best_version"; then
        best_version=$version
        best_filename=$filename
        best_sha256=$sha256
        best_size=$size
    fi
done < <(
    gzip -dc "$tmp_index" | awk -v package="$PACKAGE" -v arch="$ARCH" '
        BEGIN { RS=""; FS="\n" }
        {
            pkg=""; version=""; architecture=""; filename=""; sha256=""; size=""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^Package: /) { pkg = substr($i, 10) }
                else if ($i ~ /^Version: /) { version = substr($i, 10) }
                else if ($i ~ /^Architecture: /) { architecture = substr($i, 15) }
                else if ($i ~ /^Filename: /) { filename = substr($i, 11) }
                else if ($i ~ /^SHA256: /) { sha256 = substr($i, 9) }
                else if ($i ~ /^Size: /) { size = substr($i, 7) }
            }
            if (pkg == package && architecture == arch) {
                printf "%s\t%s\t%s\t%s\n", version, filename, sha256, size
            }
        }
    '
)

if [[ -z "$best_filename" ]]; then
    echo "Package ${PACKAGE}:${ARCH} was not found in ${index_url}" >&2
    exit 1
fi

case "$best_filename" in
    pool/*)
        if [[ "$best_filename" == *".."* || "$best_filename" =~ [[:space:]] ]]; then
            echo "Refusing unsafe repository filename: $best_filename" >&2
            exit 1
        fi
        ;;
    *)
        echo "Refusing unexpected repository filename: $best_filename" >&2
        exit 1
        ;;
esac

mkdir -p "$OUTPUT_DIR"
versioned_path="$OUTPUT_DIR/$(basename "$best_filename")"
stable_path="$OUTPUT_DIR/${PACKAGE}_${ARCH}.deb"
package_url="${REPO_URL%/}/${best_filename}"

if [[ -f "$versioned_path" ]] \
    && printf '%s  %s\n' "$best_sha256" "$versioned_path" | sha256sum --check --status; then
    echo "Already downloaded ${PACKAGE} ${best_version}: $versioned_path"
else
    tmp_package=$(mktemp "${OUTPUT_DIR}/.${PACKAGE}.XXXXXX")
    echo "Downloading ${PACKAGE} ${best_version} for ${ARCH}..."
    curl --fail --location --retry 3 --retry-delay 2 --silent --show-error \
        "$package_url" -o "$tmp_package"

    if [[ -n "$best_size" ]] && [[ "$(stat -c %s "$tmp_package")" != "$best_size" ]]; then
        echo "Size verification failed for $package_url" >&2
        exit 1
    fi

    printf '%s  %s\n' "$best_sha256" "$tmp_package" | sha256sum --check --status || {
        echo "SHA256 verification failed for $package_url" >&2
        exit 1
    }

    mv -f "$tmp_package" "$versioned_path"
    tmp_package=""
fi

# Give container builds a stable filename while retaining the versioned package.
if ! ln -f "$versioned_path" "$stable_path" 2>/dev/null; then
    cp -f "$versioned_path" "$stable_path"
fi
printf '%s\n' "$best_version" > "$OUTPUT_DIR/${PACKAGE}.version"

echo "Latest version: $best_version"
echo "Package:        $versioned_path"
echo "Build input:    $stable_path"
