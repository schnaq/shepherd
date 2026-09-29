import { notFound } from "next/navigation";
import { docsLlms, markdownSegments, source } from "@/lib/source";

export const revalidate = false;
export const dynamicParams = false;

export async function GET(_req: Request, { params }: RouteContext<"/llms.mdx/docs/[[...slug]]">) {
  const { slug } = await params;
  if (slug?.at(-1) !== "content.md") notFound();
  const page = source.getPage(slug.slice(0, -1));
  if (!page) notFound();

  return new Response(await docsLlms.page(page), {
    headers: { "Content-Type": "text/markdown" },
  });
}

export function generateStaticParams() {
  return source.getPages().map((page) => ({ slug: markdownSegments(page) }));
}
