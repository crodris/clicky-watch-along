/**
 * POST /notion-page writes a task agent's findings as a private Notion page, with a summary, sections of points, and
 * sources. The agent's loop runs in the app's Go harness, which reaches Anthropic through POST /v1/messages, and the
 * app calls this route when the agent uses its write_notion_page tool.
 */

import { z } from "zod";
import { jsonResponse, parseJSONRequest } from "./anthropic";
import { bulletedListItemBlock, createNotionPage, heading2Block, paragraphBlock, richTextItem, type NotionBlock } from "./notion";

const notionPageRequestSchema = z.object({
  title: z.string().trim().min(1).max(120),
  summary: z.string().trim().min(1).max(1500),
  sections: z
    .array(z.object({ heading: z.string().trim().min(1).max(120), points: z.array(z.string().trim().min(1).max(600)).min(1).max(10) }))
    .max(8),
  sources: z.array(z.object({ title: z.string().trim().min(1).max(200), url: z.string().url().startsWith("https://") })).max(10),
});

export type NotionPageRequest = z.infer<typeof notionPageRequestSchema>;

/** The page body, top to bottom: the summary, each section with its points, then the sources as links. */
export function notionPageBlocks(pageRequest: NotionPageRequest): NotionBlock[] {
  return [
    paragraphBlock([richTextItem(pageRequest.summary)]),
    ...pageRequest.sections.flatMap((section) => [
      heading2Block(section.heading),
      ...section.points.map((point) => bulletedListItemBlock([richTextItem(point)])),
    ]),
    ...(pageRequest.sources.length === 0
      ? []
      : [heading2Block("Sources"), ...pageRequest.sources.map((source) => bulletedListItemBlock([richTextItem(source.title, { linkURL: source.url })]))]),
  ];
}

export async function handleNotionPage(request: Request, notionAPIKey: string | undefined): Promise<Response> {
  if (notionAPIKey === undefined || notionAPIKey.length === 0) {
    return jsonResponse({ error: "NOTION_API_KEY is not set" }, 503);
  }
  const parsedRequest = await parseJSONRequest(request, notionPageRequestSchema);
  if (!parsedRequest.ok) {
    return parsedRequest.response;
  }
  const createdPage = await createNotionPage(notionAPIKey, "/notion-page", parsedRequest.requestBody.title, notionPageBlocks(parsedRequest.requestBody));
  if (!createdPage.ok) {
    return jsonResponse({ error: createdPage.error }, 502);
  }
  return jsonResponse({ pageURL: createdPage.reply.url }, 200);
}
