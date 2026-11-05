import { guidePage, guideIndex } from "../../lib/guides.js";
export const onRequestGet = ({ params }) => {
  const p = Array.isArray(params.slug) ? params.slug : (params.slug ? [params.slug] : []);
  if (p.length > 1) return guidePage("__none__");
  return p.length ? guidePage(p[0]) : guideIndex();
};
