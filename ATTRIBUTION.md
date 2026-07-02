# Attribution

Tuntun's bundled per-language language models (`FilaKit/Resources/Models/<lang>/`)
are derived from two OpenSubtitles-based datasets. The shipped model files
(vocabulary tries + quantized n-gram Bloomier filters) are **modified,
derivative material** and are offered under **CC BY-SA 4.0** (ShareAlike applies
to the bundles themselves).

## Unigrams (vocabulary + word priors)

Derived from the **FrequencyWords** dataset by **Hermit Dave** (full 2018
lists), built from the OpenSubtitles 2018 corpus.

- Source: https://github.com/hermitdave/FrequencyWords
  (`content/2018/<lang>/<lang>_full.txt`, plus `pt_br_ignored.txt` for the
  Brazilian Portuguese clitic forms)
- License: **Creative Commons Attribution-ShareAlike 4.0**
  (https://creativecommons.org/licenses/by-sa/4.0/)
- The material was modified: lists are cleaned (digit/punctuation/uppercase
  entries, split-clitic fragments, and orphan stems dropped; NFC-normalization
  collisions merged; single characters limited to real words; per-language
  count floors), pt-BR hyphenated clitics are merged back from the ignored
  file, apostrophe forms destroyed by the list tokenizer are restored from the
  OPUS corpus below with rescaled counts, and the top 80,000 words per language
  (100,000 for German and Russian) ship. Words are indexed by their
  transliterated key sequence (accents fold onto base keys, apostrophes/hyphens
  are silent) while retaining their display form.

## Bigrams (and apostrophe-form restoration)

Counted from raw-text slices of the **OPUS OpenSubtitles v2018** monolingual
corpora, built from **OpenSubtitles.org** data. OPUS requests citation rather
than imposing a formal license:

> Pierre Lison and Jörg Tiedemann, 2016: *OpenSubtitles2016: Extracting Large
> Parallel Corpora from Movie and TV Subtitles.* In Proceedings of the 10th
> International Conference on Language Resources and Evaluation (LREC 2016).

- Source: https://opus.nlpl.eu/OpenSubtitles-v2018.php
  (`https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/<lang>.txt.gz`)
- Credit to OPUS and to OpenSubtitles.org for the underlying data.

The top 200,000 bigrams per language ship as quantized log-probabilities.

## Emoji suggestion maps

The per-language word→emoji tables in
`FilaCore/Sources/FilaCore/Language/EmojiSuggestions.swift` are derived from
the **Unicode CLDR** emoji annotations (per-locale keyword and name data for
each emoji).

- Source: https://github.com/unicode-org/cldr
  (`common/annotations/<locale>.xml` and `common/annotationsDerived/<locale>.xml`
  for en, fr, de, es, it, nl, pt, ru; CLDR's base `pt` is Brazilian Portuguese,
  matching the shipped pt-BR bundle)
- License: **Unicode License v3** (https://www.unicode.org/license.txt).
  Copyright © Unicode, Inc.
- The material was modified: emoji→keyword annotations are inverted to
  keyword→emoji, restricted to emoji in Unicode's published frequency ranking
  (https://www.unicode.org/emoji/frequency.html) and to single-word keywords
  present in each language's shipped vocabulary, with ambiguous keywords
  dropped. A small curated overlay adds chat slang the annotations do not
  carry. The generator is `Tools/EmojiMapBuilder`, run by
  `Tools/rebuild-emoji-maps.sh`.

Languages included: English, French, German, Spanish, Italian, Dutch, Brazilian
Portuguese, Russian.

System spell/completion dictionaries used for out-of-vocabulary rescue are
provided by Apple via `UITextChecker` and are not redistributed.
