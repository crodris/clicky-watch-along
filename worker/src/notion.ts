/**
 * What /study-guide, /study-guide-status, and /notion-page share to write a Notion page: the few block shapes their pages use, and the
 * one place the Worker calls the Notion API. Each call names its route, so a failure is logged under the route that made it.
 */

import { z } from "zod";
import { zodIssuesOnOneLine } from "./anthropic";

// Notion's request shapes, narrowed to the few blocks the pages use.
export type NotionRichTextItem = {
  type: "text";
  text: { content: string; link?: { url: string } };
  annotations?: { bold: true };
};

export type NotionBlock =
  | { object: "block"; type: "paragraph"; paragraph: { rich_text: NotionRichTextItem[] } }
  | { object: "block"; type: "heading_2"; heading_2: { rich_text: NotionRichTextItem[] } }
  | { object: "block"; type: "bulleted_list_item"; bulleted_list_item: { rich_text: NotionRichTextItem[] } };

const notionRichTextCharacterLimit = 2000;

function truncatedForNotion(content: string): string {
  if (content.length <= notionRichTextCharacterLimit) {
    return content;
  }
  const truncatedContent = content.slice(0, notionRichTextCharacterLimit);
  const lastCharacterCode = truncatedContent.charCodeAt(notionRichTextCharacterLimit - 1);
  // A high surrogate left at the end is half of an emoji, which Notion would reject.
  const endsInHalfOfAnEmoji = lastCharacterCode >= 0xd800 && lastCharacterCode <= 0xdbff;
  return endsInHalfOfAnEmoji ? truncatedContent.slice(0, -1) : truncatedContent;
}

export function richTextItem(content: string, options: { linkURL?: string; bold?: boolean } = {}): NotionRichTextItem {
  return {
    type: "text",
    text: {
      content: truncatedForNotion(content),
      ...(options.linkURL !== undefined ? { link: { url: options.linkURL } } : {}),
    },
    ...(options.bold === true ? { annotations: { bold: true as const } } : {}),
  };
}

export function paragraphBlock(richText: NotionRichTextItem[]): NotionBlock {
  return { object: "block", type: "paragraph", paragraph: { rich_text: richText } };
}

export function heading2Block(heading: string): NotionBlock {
  return { object: "block", type: "heading_2", heading_2: { rich_text: [richTextItem(heading)] } };
}

export function bulletedListItemBlock(richText: NotionRichTextItem[]): NotionBlock {
  return { object: "block", type: "bulleted_list_item", bulleted_list_item: { rich_text: richText } };
}

const notionAPIBaseURL = "https://api.notion.com/v1";
const notionAPIVersion = "2026-03-11";

const notionPageReplySchema = z.object({ id: z.string(), url: z.string() });

export type NotionCallResult<Reply> = { ok: true; reply: Reply } | { ok: false; error: string; status?: number };

export async function callNotion(
  notionAPIKey: string,
  routeName: string,
  method: "GET" | "POST" | "PATCH",
  path: string,
  requestBody?: unknown,
): Promise<NotionCallResult<unknown>> {
  try {
    const notionResponse = await fetch(`${notionAPIBaseURL}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${notionAPIKey}`,
        "notion-version": notionAPIVersion,
        "content-type": "application/json",
      },
      body: requestBody === undefined ? undefined : JSON.stringify(requestBody),
    });
    if (!notionResponse.ok) {
      const errorText = await notionResponse.text();
      console.error(`[${routeName}] Notion API error ${notionResponse.status} on ${method} ${path}: ${errorText}`);
      return { ok: false, error: `Notion returned ${notionResponse.status}`, status: notionResponse.status };
    }
    return { ok: true, reply: await notionResponse.json() };
  } catch (error) {
    console.error(`[${routeName}] Notion request failed on ${method} ${path}:`, error);
    return { ok: false, error: "Notion could not be reached" };
  }
}

export async function createNotionPage(
  notionAPIKey: string,
  routeName: string,
  title: string,
  children: NotionBlock[],
): Promise<NotionCallResult<{ id: string; url: string }>> {
  const createdPage = await callNotion(notionAPIKey, routeName, "POST", "/pages", {
    parent: { type: "workspace", workspace: true },
    properties: { title: { title: [richTextItem(title)] } },
    children,
  });
  if (!createdPage.ok) {
    return createdPage;
  }
  const parsedPage = notionPageReplySchema.safeParse(createdPage.reply);
  if (!parsedPage.success) {
    return { ok: false, error: `Notion's reply was not a page: ${zodIssuesOnOneLine(parsedPage.error)}` };
  }
  return { ok: true, reply: parsedPage.data };
}
