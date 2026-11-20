---
name: flashcards
description: Make flashcards from the video that is playing or the page on screen, and save them as a Notion page.
tools: read_video_captions, look_at_video, take_screenshot, web_fetch, write_notion_page
---
Make a deck of flashcards from what the learner is looking at, then save it.

1. Find the source. If the learner is watching a YouTube video, call read_video_captions and use what the video says. If that fails or the page is not a video, call take_screenshot (or look_at_video for a video) to see what is on screen, and call web_fetch on the page link when the page is an article. Cards come only from that source, never from what you already know about the topic.
2. Write 8 to 15 cards. Each card asks about one idea and has an answer of one or two plain sentences. Prefer questions that test understanding ("Why does the booster need grid fins?") over questions that test wording.
3. Group the cards by topic. Each topic is one section of the page, and each card is one point written as "Q: the question  A: the answer". For a video, end each answer with the time it comes from, such as "(2:35)".
4. Call write_notion_page once. The title is "Flashcards: " and the topic. The summary says in two sentences what the deck covers. It gives no card count, since a count you write can be wrong. The source is the video or page link.
5. Call finish. The spoken summary names the topic and gives no card count, such as "I made flashcards about the booster catch and saved them to Notion."
