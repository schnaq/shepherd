import { notFound } from "next/navigation";
import { docsLlms, markdownSegments, source } from "@/lib/source";

export const revalidate = false;
export const dynamicParams = false;

export async function GET(_req: Request, { params }: RouteContext<"/llms.mdx/[lang]/docs/[[...slug]]">) {
  const { lang, slug } = await params;
  if (slug?.at(-1) !== "content.md") notFound();
  const page = source.getPage(slug.slice(0, -1), lang);
  if (!page) notFound();

  return new Response(await docsLlms.page(page), {
    headers: { "Content-Type": "text/markdown" },
  });
}

export function generateStaticParams() {
  return source.getLanguages().flatMap(({ language, pages }) =>
    pages.map((page) => ({ lang: language, slug: markdownSegments(page) })),
  );
}
