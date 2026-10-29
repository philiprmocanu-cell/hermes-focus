import Foundation

// MARK: - Jev, the second-by-second judge (port of brain/jev.py)
//
// The pure half of the judge, ported so the Mac app can judge a focus block
// with no server, on the user's own TypeSafe key: the state Jev reads, the
// questions it answers, how the answers become a verdict row, and the
// deterministic rules on top (distraction sites, his rulings, steps, away,
// nudges, minute frames). Names follow brain/jev.py (snake_case → camelCase)
// and every number is the same. Rows, states and answers are JSON objects
// (`Judge.Dict`) with the same keys as the Python dicts, so they round-trip
// to the same JSON. Parity is pinned by scripts/fixtures_judge.py →
// Tests/Fixtures/judge/*.json → JudgeTests.

public enum Judge {
    public typealias Dict = [String: JSONValue]

    public static let model = "jev-latest"
    public static let imageHeader = (name: "TypeSafe-Danger-Zone-Images", value: "true")
    public static let maxTextChars = 6000           // what the app sends of the visible text
    public static let recentRows = 12               // judged seconds Jev gets to re-read
    public static let imageFreshS = 6.0             // a screenshot speaks for its screen this long
    public static let offTaskS = 20.0               // continuous confident off task this long → nudge
    public static let offTaskGapS = 12.0            // verdicts further apart than this break a run
    public static let offTaskOnGoal = 0.3           // on_goal under this, confidently, is off task
    public static let offTaskConfidence = 0.7
    public static let related = 0.5                 // serves_goal at least this = tied to the task
    public static let step = 0.6                    // step_toward_goal at least this = a step toward it
    public static let stepOnGoal = 0.6              // a step's on_goal is lifted to at least this
    public static let distractionS = 5.0            // a distraction site this long in front = off task
    public static let distractionOnGoal = 0.05
    public static let nudgeGraceS = 30.0            // never a nudge this early in a block
    public static let idleS = 120                   // no input this long = away from the desk
    public static let readingIdleS = 360            // ...on reading material, or while studying
    public static let heartbeatS = 5.0              // nothing changed: ask Jev again only this often
    public static let minuteS = 60.0                // seconds of verdicts folded into one frame
    public static let minuteMinRows = 20            // ...never from fewer seconds than this
    public static let progressConfidence = 0.6      // progress only rises on a verdict this sure
    public static let storyWindowS = 600.0          // the story covers the last ten minutes
    public static let storyMaxChars = 360
    public static let storyMinS = 3.0               // a screen shown for less than this is left out of the story
    public static let goalQPrefix = "goal_"         // goal-specific question ids: goal_q1, goal_q2, ...
    public static let goalQMax = 8                  // at most this many per goal
    public static let goalQRubricMax = 26           // the rubric's tells (14 on + 4 rulings + 8 off)
    public static let rubricQPrefixes = ["rub_on_", "rub_off_"]
    public static let goalQMaxChars = 160           // each question's text
    public static let goalTell = 0.7                // a goal question answered yes at least this = a tell
    public static let goalOffOnGoal = 0.2           // an off-task tell caps on goal here
    public static let todayMaxChars = 400           // the owner's "today" line
    public static let longText = 3000               // visible text this long is a long article or reply

    // The rubric's own ids and threshold (brain/rubric.py), needed by the
    // questions and the milestones. Kept here so the judge does not depend on
    // the rubric port.
    public static let rubricPrefixOn = "rub_on_"
    public static let rubricPrefixOff = "rub_off_"
    public static let rubricPrefixMs = "ms_"
    public static let milestoneYes = 0.7

    // The general checks.
    public static let checkPrefix = "chk_"
    public static let checkTell = 0.6               // a check answered yes at least this = a tell
    public static let checkCap = 0.7                // a "repeating" / "hopping" yes this sure caps working and smart...
    public static let checkCapTo = 0.4              // ...at this
    public static let checkFloor = 0.1              // a check answered below this is no evidence at all
    public static let checkBlend = 0.6              // on goal = 0.6 x the checks + 0.4 x the old on-goal score
    public static let checkMaxChars = 110
    public static let escalateConfidence = 0.6      // combined confidence under this → the smarter model
    public static let escalateLow = 0.35, escalateHigh = 0.65
    public static let tellsShown = 5

    /// Score questions and their number of levels.
    public static let scoreLevels: [(key: String, levels: Int)] = [
        ("on_goal", 4), ("working", 4), ("producing", 4), ("quality", 4), ("smart", 4), ("progress", 5)]

    // Apps whose screens are pictures, not text: the screenshot is sent sooner.
    public static let pictureApps = ["figma", "sketch", "photoshop", "illustrator", "final cut", "imovie", "preview",
                                     "photos", "quicktime", "keynote", "blender", "fusion", "kicad", "eagle", "altium"]
    public static let pictureHosts = ["youtube.com", "youtu.be", "vimeo.com", "figma.com", "canva.com", "netflix.com",
                                      "twitch.tv", "instagram.com", "tiktok.com", "cosmos.so"]

    // Reading material: a page here earns the longer idle allowance.
    public static let readingHosts = ["wwnorton.com", "zybooks.com", "instructure.com", "canvas", "docs.", "developer.",
                                      "readthedocs", "wikipedia.org", "arxiv.org", "medium.com", "substack.com",
                                      "scholar.google", "jstor.org", "pubmed", "openstax.org", "khanacademy.org",
                                      "coursera.org", "edx.org", "pearson.com", "mheducation.com", "cengage.com",
                                      "notion.site", "gitbook.io", "learn.microsoft.com", "docs.google.com/document"]
    public static let readingApps = ["preview", "books", "skim", "acrobat", "pdf expert", "kindle"]

    // MARK: Activity and the fixed questions

    public static let activityKeys = ["making", "studying", "consuming", "static", "other"]

    public static let activity: JSONValue = .object([
        "making": .object([
            "what": .string("writing, coding, editing, solving, building, or directing an AI chat to build "
                            + "or fix something (a Claude or ChatGPT chat with code or a concrete ask is making); "
                            + "writing an email or message that the goal needs"),
            "examples": strings(["Xcode with a diff", "Claude chat asking for a fix", "Google Doc being typed into",
                                 "a Gmail reply being drafted"])]),
        "studying": .object([
            "what": .string("reading or studying material — a paper, docs, a textbook or ebook, a course "
                            + "page, a tutorial, a long AI answer, search results being read for the work"),
            "examples": strings(["a PDF chapter", "zyBooks", "developer documentation", "Canvas course page"])]),
        "consuming": .object([
            "what": .string("feeds, social media, entertainment video, news, shopping, memes, chat "
                            + "unrelated to work"),
            "examples": strings(["Instagram", "YouTube Shorts", "Reddit front page", "a shopping cart"])]),
        "static": .object([
            "what": .string("no keyboard, mouse or scroll for longer than his idle allowance "
                            + "(since_last_second.no_input_too_long) — he has likely stepped away"),
            "not_for": .string("reading material inside its allowance, or a page being scrolled or typed into")]),
        "other": .object([
            "what": .string("settings, Finder, a file picker, a terminal with no output, a blank window, an "
                            + "app switching moment"),
            "not_for": .string("anything that is plainly work or plainly a distraction")]),
    ])

    private static let see = "Read `screen_now.screenshot` when it is present: it is the screen itself. "

    private static func scoreQ(_ instructions: String, _ criteria: [String]) -> JSONValue {
        .object(["type": .string("score"), "instructions": .string(instructions), "criteria": strings(criteria)])
    }

    private static func noulQ(_ instructions: String) -> JSONValue {
        .object(["type": .string("noul"), "instructions": .string(instructions)])
    }

    public static let questions: Dict = [
        "activity": .object([
            "type": .string("choice"),
            "instructions": .string("What is he doing on this screen right now? " + see
                                    + "Judge the content, not the app name."),
            "criteria": activity]),
        "on_goal": scoreQ("How clearly does this screen serve THIS block's goal (the specific goal "
                          + "if given), read together with `story_so_far` and `goal.related`? " + see
                          + "Supporting or directly: the material the goal needs; a lookup or a "
                          + "search whose words serve the goal or what he was just doing; an email or "
                          + "chat thread with a person, company or project the goal names; an AI chat "
                          + "working on the goal's project. Unrelated only when nothing on the screen "
                          + "connects to the goal.",
                          ["unrelated", "adjacent", "supporting", "directly"]),
        "working": scoreQ("How purposeful and productive is this moment toward the goal? "
                          + "Making or targeted reading of a specific source = high; aimless "
                          + "browsing, hopping between pages = low; entertainment = none.",
                          ["none", "low", "medium", "high"]),
        "producing": scoreQ("IGNORE the stated goal. Is he actively making or doing real work on "
                            + "WHATEVER is on screen — creating, editing, coding, writing, "
                            + "debugging, purposeful research? Real work on a different project "
                            + "is still high.",
                            ["none", "low", "medium", "high"]),
        "quality": scoreQ("Is this GOOD work toward the goal: clear, direct text or prompts "
                          + "that serve it, the right specific material read in a focused way? "
                          + "Judge like a strict coach measuring him against the most productive "
                          + "people alive. Rambling, retyping, aimless hopping or unrelated content "
                          + "is poor.",
                          ["poor", "ok", "good", "excellent"]),
        "smart": scoreQ("Is he working SMART, not just hard: an efficient approach, clear "
                        + "direct prompts, using AI and tools well, reusing instead of retyping? "
                        + "Judge like a strict coach measuring him against the most productive "
                        + "people alive; never reward merely having the right app open.",
                        ["no", "somewhat", "mostly", "yes"]),
        "progress": scoreQ("How far toward ACHIEVING the specific goal has he got in this block, "
                           + "judging from the screen and the progress so far? Never below "
                           + "the progress so far unless the work was undone.",
                           ["none", "started", "halfway", "mostly", "done"]),
        "serves_goal": noulQ("The screen is on a site or app usually treated as a distraction "
                             + "(Instagram, LinkedIn, X, Reddit, YouTube, Discord, a chat app) but "
                             + "he is messaging or reading something tied to THIS task: a DM with "
                             + "someone the goal names (`goal.related.people`) or a teammate about "
                             + "this work, a thread answering the exact problem, a tutorial on the "
                             + "goal's own topic, a product page for a part or tool the goal's "
                             + "project needs. A feed, a profile, a video or a product unrelated to "
                             + "the goal is NOT."),
        "step_toward_goal": noulQ("Given what he was just doing (`story_so_far`, "
                                  + "`recent_verdicts_oldest_first`) and what the goal involves "
                                  + "(`goal.related`), is this screen a STEP toward the goal — a "
                                  + "quick lookup, a sub-problem of it, a search whose words serve "
                                  + "it (`screen_now.search_words`), contacting or reading a message "
                                  + "from someone the goal names? A feed, entertainment, or a new "
                                  + "unrelated topic is not."),
    ]

    public static let standingRules: [String] = [
        "Reading or studying material relevant to the goal is work, not a failure.",
        "A Claude chat (desktop or claude.ai) directing code or writing for the goal's project IS his "
            + "work: making. The Claude desktop app shows almost no text — judge it from the screenshot and "
            + "the story.",
        "Xcode, the iOS Simulator or a terminal running an agent on the goal's app: making.",
        "Email or chat with a person, company or project the goal names (goal.related) is on task: "
            + "reading or writing that thread IS the work.",
        "A web search is judged by its WORDS (screen_now.search_words) against the goal, goal.related and "
            + "story_so_far, never by being a search page: 'time in japan now' while writing to a partner in "
            + "Japan is a step toward the goal.",
        "A YouTube tutorial or lecture on the goal's own topic: studying, serves the goal.",
        "Instagram, TikTok, YouTube Shorts or home feed, Reddit front page, X feed, LinkedIn feed, "
            + "shopping: consuming, unrelated — unless he is messaging or reading something tied to the task.",
        "No input for a while on reading material (a PDF, an ebook, zyBooks, docs, Canvas, a long "
            + "article, a long Claude reply) is reading, not away, until idle_allowance_s.",
        "Finder, the desktop or a file picker for a moment: other, not consuming.",
        "his_rulings_this_block are his own corrections during this block: they override your reading.",
        "The chk_ questions are general checks: 'the task' is this block's goal (goal.specific when given). "
            + "Answer each from the screen, title, URL, story_so_far and screenshot; yes only when it plainly shows.",
    ]

    // MARK: The general checks

    public struct Check: Equatable, Sendable {
        public enum Means: String, Sendable { case onTask = "on_task", offTask = "off_task", neutral }
        public let id: String
        public let text: String
        public let means: Means
        public let weight: Double
        public let feeds: [String]

        public var json: JSONValue {
            .object(["id": .string(id), "text": .string(text), "means": .string(means.rawValue),
                     "weight": .number(weight), "feeds": strings(feeds)])
        }
    }

    private static func chk(_ id: String, _ means: Check.Means, _ weight: Double, _ text: String,
                            feeds: [String] = ["on_goal"]) -> Check {
        Check(id: id, text: text, means: means, weight: weight, feeds: feeds)
    }

    public static let generalChecks: [Check] = [
        // --- on task: a yes is a sign he is doing this goal's work
        chk("contact", .onTask, 1.0,
            "Is he writing to, replying to or reading a message from someone about the task (any email, chat or DM)?"),
        chk("search", .onTask, 0.9,
            "Is he searching for words that serve the task or what he was doing the last few minutes?"),
        chk("ai_agent", .onTask, 1.0,
            "Is an AI chat or coding agent working on the task's project (its prompt, code or output is about it)?"),
        chk("reference", .onTask, 0.9,
            "Is he reading reference or study material on the task's topic (docs, a textbook, a paper, an article)?"),
        chk("making", .onTask, 1.0,
            "Is he writing or editing the document, code, design or message that IS the task?"),
        chk("title", .onTask, 0.6,
            "Does the window, tab or document title name the task, its project, its file or a person it involves?"),
        chk("testing", .onTask, 1.0,
            "Is he reviewing, running or testing the task's output (a preview, simulator, build, terminal running it)?"),
        chk("lookup", .onTask, 0.8,
            "Is he looking up a tool, part, price, setting or how-to that the task needs?"),
        chk("planning", .onTask, 0.8,
            "Is he planning, outlining or taking notes for the task (a to-do list, outline, notes, whiteboard)?"),
        chk("meeting", .onTask, 1.0,
            "Is he on a call or in a meeting about the task, or reading its agenda or notes?"),
        chk("waiting", .onTask, 0.6,
            "Is he waiting on a build, upload or agent for the task with nothing unrelated open?"),
        chk("sub_problem", .onTask, 0.8,
            "Is this a sub-problem the task led to, going by the story (an error, a broken tool, a setup step)?"),
        chk("form", .onTask, 0.8,
            "Is he filling in a form, portal or account page the task needs (a submission, an upload, a sign-up)?"),
        chk("lecture", .onTask, 0.8,
            "Is he watching a lecture, tutorial or demo on the task's own topic?"),
        chk("files", .onTask, 0.6,
            "Is he opening, saving, moving or sharing a file that belongs to the task?"),
        chk("continuing", .onTask, 0.7,
            "Is this the same task work the story shows he was doing a minute ago, carried on?"),
        chk("reviewing", .onTask, 0.9,
            "Is he reviewing someone else's work for the task (a pull request, comments, suggested edits)?"),
        chk("data", .onTask, 0.8,
            "Is he reading data the task is about (a dashboard, a log, a spreadsheet, results)?"),
        // --- off task: a yes is a sign he is not doing this goal
        chk("feed", .offTask, 1.0,
            "Is he scrolling a feed (social, video, news or forum front page) rather than reading one thing?"),
        chk("entertainment", .offTask, 1.0,
            "Is he watching entertainment unrelated to the task (a show, a stream, clips, memes)?"),
        chk("shopping", .offTask, 0.9,
            "Is he shopping or browsing products unrelated to the task?"),
        chk("chat_unrelated", .offTask, 0.8,
            "Is he in a chat, DM or email thread unrelated to the task?"),
        chk("news", .offTask, 0.8,
            "Is he reading news, an article or a forum thread unrelated to the task?"),
        chk("game", .offTask, 1.0,
            "Is he playing a game or on a game site?"),
        chk("hopping", .offTask, 0.7,
            "Is he hopping between unrelated pages or apps without settling on one (see the story)?",
            feeds: ["on_goal", "working", "smart"]),
        chk("new_topic", .offTask, 0.8,
            "Has he moved on to a new topic unrelated to both the goal and the story so far?"),
        chk("personal_admin", .offTask, 0.8,
            "Is he on personal admin unrelated to the task (banking, travel, bills, appointments, deliveries)?"),
        chk("notifications", .offTask, 0.8,
            "Is he checking notifications, likes, followers, views or stats unrelated to the task?"),
        chk("profiles", .offTask, 0.7,
            "Is he looking through someone's profile or photos for no reason the task gives?"),
        chk("other_project", .offTask, 0.7,
            "Is he doing real work, but on a DIFFERENT project than this goal?"),
        chk("ai_unrelated", .offTask, 0.8,
            "Is an AI chat on screen about a topic unrelated to the task?"),
        chk("passive", .offTask, 0.5,
            "Is the screen passive: nothing to read, nothing typed or scrolled, nothing for the task playing?"),
        chk("repeating", .offTask, 0.8,
            "Is he redoing the same thing again (retyping, re-running the same step, re-reading the same page)?",
            feeds: ["working", "smart"]),
        // --- neutral: says where he is, moves nothing
        chk("settings", .neutral, 0.5, "Is it a settings pane, preferences window or system dialog?"),
        chk("finder", .neutral, 0.5, "Is it Finder, the desktop, a file picker or a downloads list?"),
        chk("switching", .neutral, 0.5, "Is this an app-switch moment: a blank, loading or half-drawn window?"),
    ]

    public static let checkIds: [String] = generalChecks.map(\.id)

    public static let checkQuestions: Dict = Dictionary(uniqueKeysWithValues: generalChecks.map {
        (checkPrefix + $0.id, noulQ($0.text))
    })

    /// The bank as [{id, text, means}] for the sense log.
    public static func checksListing() -> [JSONValue] {
        generalChecks.map { .object(["id": .string($0.id), "text": .string($0.text), "means": .string($0.means.rawValue)]) }
    }

    static func strings(_ xs: [String]) -> JSONValue { .array(xs.map { .string($0) }) }
}
