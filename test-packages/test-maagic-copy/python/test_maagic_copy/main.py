# -*- mode: python; python-indent: 4 -*-
import ncs

from maagic_copy.maagic_copy import maagic_copy

class TestAction(ncs.dp.Action):
    @ncs.dp.Action.action
    def cb_action(self, uinfo, name, kp, action_input, action_output):
        maagic_copy(action_input, action_output)


class AppComponent(ncs.application.Application):
    def setup(self):
        self.register_action('test-action', TestAction)


if __name__ == '__main__':
    import logging
    logging.basicConfig(level=logging.DEBUG)
    with ncs.maapi.single_write_trans('', 'system') as t:
        root = ncs.maagic.get_root(t)
        maagic_copy(root.src, root.dst)
        t.apply()
