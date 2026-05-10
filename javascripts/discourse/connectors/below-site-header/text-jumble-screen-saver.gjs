/* eslint-disable ember/no-classic-components */
/* global settings */
import Component from "@ember/component";
import { tagName } from "@ember-decorators/component";
import TextJumbleScreenSaver from "../../components/text-jumble-screen-saver";

@tagName("")
export default class TextJumbleScreenSaverConnector extends Component {
  static shouldRender() {
    return (
      settings.text_jumble_enabled && settings.text_jumble_idle_seconds > 0
    );
  }

  <template><TextJumbleScreenSaver /></template>
}
