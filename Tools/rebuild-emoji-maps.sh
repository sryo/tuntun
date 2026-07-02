#!/bin/zsh
# Regenerate FilaCore/Sources/FilaCore/Language/EmojiSuggestions.swift from the
# Unicode CLDR emoji annotations, filtered against the shipped model bundles in
# FilaKit/Resources/Models (rebuild those first — rebuild-models.sh runs both).
# Sources and licenses: see ATTRIBUTION.md and the header of
# EmojiMapBuilder/Sources/EmojiMapBuilder/main.swift.
set -euo pipefail
cd "$(dirname "$0")"

LANGS=(en fr de es it nl pt ru)
WORK=${1:-corpora}
CLDR="$WORK/cldr"
mkdir -p "$CLDR"

for code in $LANGS; do
    if [[ ! -f "$CLDR/$code.xml" ]]; then
        curl -fL -o "$CLDR/$code.xml" \
            "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotations/$code.xml"
    fi
    if [[ ! -f "$CLDR/${code}_derived.xml" ]]; then
        curl -fL -o "$CLDR/${code}_derived.xml" \
            "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotationsDerived/$code.xml"
    fi
done

swift run -c release --package-path EmojiMapBuilder EmojiMapBuilder \
    "$CLDR" "../FilaKit/Resources/Models" \
    "../FilaCore/Sources/FilaCore/Language/EmojiSuggestions.swift"
