/* global settings */

import { apiInitializer } from "discourse/lib/api";

export default apiInitializer("1.14.0", (api) => {
  if (!settings.text_jumble_route_enabled) {
    return;
  }

  api.addCommunitySectionLink({
    name: "text-jumble",
    route: "text-jumble",
    title: "Text Jumble",
    text: "Text Jumble",
  });
});
