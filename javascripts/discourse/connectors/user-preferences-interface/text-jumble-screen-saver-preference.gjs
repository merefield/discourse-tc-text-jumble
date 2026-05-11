/* global settings */
import Component from "@glimmer/component";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { i18n } from "discourse-i18n";

import {
  isScreenSaverDisabled,
  setScreenSaverDisabled,
} from "../../lib/text-jumble-preferences";

export default class TextJumbleScreenSaverPreference extends Component {
  @service currentUser;

  @tracked disabled = isScreenSaverDisabled(this.currentUser);

  get preferenceUser() {
    return this.args.outletArgs?.model || this.args.model || this.currentUser;
  }

  get shouldRender() {
    return (
      settings.text_jumble_screen_saver_enabled &&
      this.currentUser?.id &&
      this.preferenceUser?.id === this.currentUser.id
    );
  }

  @action
  updateDisabled(event) {
    this.disabled = event.target.checked;
    setScreenSaverDisabled(this.currentUser, this.disabled);
  }

  <template>
    {{#if this.shouldRender}}
      <div
        class="control-group text-jumble-screen-saver-local-preference"
        data-setting-name="text-jumble-screen-saver-local-preference"
      >
        <label class="control-label">
          {{i18n (themePrefix "text_jumble.preferences.title")}}
        </label>

        <div class="controls">
          <label class="checkbox-label">
            <input
              type="checkbox"
              checked={{this.disabled}}
              {{on "change" this.updateDisabled}}
            />
            {{i18n
              (themePrefix "text_jumble.preferences.disable_screen_saver")
            }}
          </label>

          <div class="instructions">
            {{i18n
              (themePrefix "text_jumble.preferences.local_storage_notice")
            }}
          </div>
        </div>
      </div>
    {{/if}}
  </template>
}
