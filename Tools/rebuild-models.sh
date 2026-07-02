#!/bin/zsh
# Regenerate FilaKit/Resources/Models from public corpora — the pipeline that
# produced the shipped bundles. Sources and licenses: see ATTRIBUTION.md and the
# header of ModelBuilder/Sources/ModelBuilder/main.swift.
#
# Downloads (cached in Tools/corpora, gitignored):
#  * Hermit Dave's FrequencyWords FULL 2018 lists — unigram ranking
#  * OPUS OpenSubtitles v2018 raw mono slices, first 40 MiB per language —
#    bigrams + apostrophe-form restoration. A truncated gzip prefix decompresses
#    to a valid line stream, so the trailing gunzip error is expected.
set -euo pipefail
cd "$(dirname "$0")"

LANGS=(en fr de es it nl pt_br ru)
WORK=${1:-corpora}
FREQ="$WORK/freq"
CORPUS="$WORK/corpus"
OUT="../FilaKit/Resources/Models"
mkdir -p "$FREQ" "$CORPUS"

for code in $LANGS; do
    if [[ ! -f "$FREQ/${code}_full.txt" ]]; then
        curl -fL -o "$FREQ/${code}_full.txt" \
            "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/$code/${code}_full.txt"
    fi
    if [[ ! -f "$CORPUS/$code.txt" ]]; then
        curl -fL -r 0-41943039 -o "$CORPUS/$code.txt.gz" \
            "https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/$code.txt.gz"
        gzip -dc "$CORPUS/$code.txt.gz" > "$CORPUS/$code.txt" 2>/dev/null || true
        rm "$CORPUS/$code.txt.gz"
    fi
done

# pt-BR hyphenated clitics ("deixe-me") that the 2018 tokenizer routed out of
# the main list; ModelBuilder merges them back. Optional input.
if [[ ! -f "$FREQ/pt_br_ignored.txt" ]]; then
    curl -fL -o "$FREQ/pt_br_ignored.txt" \
        "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/pt_br/pt_br_ignored.txt" \
        || echo "warning: pt_br_ignored.txt not fetched; clitic merge will be skipped" >&2
fi

swift run -c release --package-path ModelBuilder ModelBuilder "$FREQ" "$CORPUS" "$OUT"
