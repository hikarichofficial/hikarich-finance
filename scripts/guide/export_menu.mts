// Prints the menu tree and the page descriptions as JSON, for scripts/guide/build_guide_pdf.py (so the PDF's
// "Fungsi Menu & Sub-Menu" chapter can never drift from the real menu and the help text under each page title).
//   node --experimental-strip-types scripts/guide/export_menu.mts
import { NAVIGATION } from "../../src/domain/shell/navigation.ts";
import { PAGE_HELP } from "../../src/content/pageHelp.ts";

console.log(JSON.stringify({ nav: NAVIGATION, help: PAGE_HELP }));
