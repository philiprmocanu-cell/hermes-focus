# Hermes Focus

A Mac app that keeps you on task. You type what you are going to do, start a 25-minute block, and the app watches your screen and tells you when you have drifted. At the end of each block you get a score out of 1,000 and a line or two of advice.

Everything runs on your own Mac with your own keys. There is no server, no account with us, and nothing about your screen is stored anywhere.

## How it judges

- Once a second the app reads the front window: the app name, the window title, the page address and the visible text. On a screen change it also takes a small screenshot. That goes to TypeSafe's Jev model with your key and comes back with answers to a fixed set of questions: what you are doing, whether it serves your goal, and about forty yes/no checks such as "is he writing to someone about the task" or "is he scrolling a feed."
- When you set a goal, a written rubric is made for it: the kind of block, the balance between focus and output, three or four milestones that have to appear on screen, and what on-task and off-task look like for this goal. You can fix it with one typed line before the block starts.
- A nudge appears only after about twenty seconds of confident drift. It has one button, "I'm on task." Click it if the judge is wrong, and that screen counts as work for the rest of the block.
- Your score weighs focus and output by the rubric's balance. A reading block is almost all focus. A building block is mostly output, judged by milestones reached. A thousand needs every milestone, at least 95% of judged seconds on task, and no time on distraction sites.

With an Anthropic key the app also writes the rubric, takes a second look before every nudge, and gives advice after each block. Without one it still judges and scores on TypeSafe alone.

## Install

Requirements: a Mac with Apple silicon, macOS 14 or newer, Xcode command line tools.

```bash
git clone <this repo>
cd hermes-focus
./install.sh --launch
```

On first launch choose **Run on my own keys**, then paste a TypeSafe key from https://console.typesafe.ai/keys. The Anthropic key is optional. The app asks for Screen Recording and Accessibility permissions; both are needed for judging.

## Where your data lives

`~/Library/Application Support/HermesFocus/local/`: your settings, block history, the rubric for each goal, your "I'm on task" corrections, and a markdown report per day. Keys live in the macOS Keychain. Screen text and screenshots are sent for judging and discarded; they are never written to disk.

## Cost

TypeSafe charges per token of input. A full day of blocks is roughly one to three dollars. The Anthropic calls are a few cents per block.

## Development

```bash
swift test       # pure logic: judge, scoring, rubric, local brain
./install.sh     # build, sign, install
```

The judge rules, the scoring and the rubric writer are in `Sources/FocusCore` and were ported from a Python reference with fixture-for-fixture parity tests, so changes to the rules should come with a fixture.

## License

MIT.
