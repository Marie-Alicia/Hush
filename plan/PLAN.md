# Hush: product plan

## The problem

- New parents are anxious about how their baby is doing, especially at night.
- Crying they can't explain adds to their stress.
- A parent's stress is felt by the baby, which makes settling harder.

## What Hush does

1. **Listens** through a Plaud NotePin S, the iPhone's microphone or an existing baby monitor. Only cries are kept.
2. **Learns this baby.** After each cry the parent taps what settled it. Hush combines the sound with the baby's routine (time since the last feed, time asleep) and shows ranked guesses with reasons.
   - It only shows guesses once listening to the cry beats guessing from routine alone.
   - It never claims to "translate" cries. Research shows universal cry translation doesn't work reliably.
3. **Looks after the parent:**
   - Calm Coach: 60–90 second guided calm-downs.
   - Settle Guide: includes the ICON safe-break message ("It's OK to walk away", "Never shake a baby").
   - Daily check-ins with mood trends.
   - Tag-team nights with a partner.
   - Morning reflection.
   - Crisis support.
4. **Reports** to the baby's health team as PDFs, with the parent choosing what's included:
   - health visitor summary
   - urgent summary for a doctor
   - the parent's own wellbeing summary for their GP

## Technology choices

| Job | Choice |
| --- | --- |
| Cry detection on the phone | YAMNet (TensorFlow Lite), using AudioSet's "Baby cry, infant cry" class |
| Confirm cries on the server | PANNs CNN14 |
| Sound features | openSMILE (eGeMAPS: pitch, jitter, shimmer), librosa |
| Cry fingerprints | BEATs or LAION-CLAP embeddings, stored with pgvector |
| Per-baby classifier | Small model trained on the parent's labels plus routine features |
| Listening to a clip with context | Gemini audio models via OpenRouter (e.g. `google/gemini-3.8-flash`) |
| Insights, reflections, messages | Claude Sonnet 5.5 (from structured logs only, never audio); Claude Haiku 4.5 for quick replies |
| Crisis detection | Fixed keyword and pattern rules first, then a classifier; if in doubt, show the crisis contacts |
| Capture hardware | Plaud NotePin S through the Plaud Embedded SDK: live 16 kHz mono PCM over Bluetooth (`blePcmData`) |

## Safety and privacy

- **Not a medical device, no diagnosis.** Red-flag cries show NHS advice.
- **Crisis contacts appear immediately:**
  - UK: Samaritans 116 123, NHS 111 (mental health option), 999
  - US: 988 and 1-833-TLC-MAMA
- **Only cries are kept.** Everything else the microphone hears is deleted on the phone right away, and cry clips are deleted after 90 days.
- **Wellbeing data stays with each parent.** It's private to them and shared only with their consent. Under UK GDPR it counts as special category data.
- **Clinical review.** Calm-down scripts and crisis flows need review by a perinatal mental health clinician.
- **Regulation.** Crisis tools and clinician reports may bring Hush under MHRA medical-device rules and the NHS DTAC standard. Get expert advice early.

## Competitors

Research from September 2026, with web traffic from Similarweb, August 2026.

| Type | Examples | Gap Hush fills |
| --- | --- | --- |
| Smart camera monitors | Nanit (about 663K visits a month, 87% US), Cubo AI | Tied to their own hardware; no per-baby learning; nothing for the parent |
| Monitors with cry translation | Philips Avent and Maxi-Cosi (Zoundream inside) | Fixed categories across all babies |
| Vitals monitors | Owlet (Owlet360 launched in the UK Dec 2025), Masimo Stork | Monitor vital signs, not crying |
| Cry translator apps | Nanni AI, Cappella, ChatterBaby | Fixed categories; no wellbeing features; no clinician reports |
| Baby trackers | Huckleberry (with its Berry AI), Glow Baby | No cry listening; nothing for parent wellbeing |
| Parent wellbeing | Peanut, Expectful | Not connected to what the baby is doing |

**Where Hush wins:**
- It learns each baby's own cries.
- It works with hardware families already own.
- It supports the parent in the moment.
- It produces reports for health visitors and GPs.
- It's UK-first. The big players get only 1.7–10% of their traffic from the UK.

**Biggest threats:**
- Nanit (raised $50M, moving into "parenting intelligence")
- Philips with Zoundream (strong UK retail presence)
- Huckleberry (one feature away from listening to cries)
- Nanni AI
- Owlet

## Roadmap

1. **Validate:** interview 20 families and a perinatal mental health clinician; test the NotePin S stream overnight.
2. **Data collection app:** cry detection plus one-tap labels, with no guesses yet.
3. **Model testing:** per-baby models against a routine-only baseline.
4. **Beta:** guesses with reasons, the wellbeing features, and reports.
5. **NHS pilots:** work with health visitor teams.
