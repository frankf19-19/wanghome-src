import { caseShare } from "../../lib/share.js";
export const onRequest = ({ params }) => caseShare(params.id);
