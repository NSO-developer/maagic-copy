# -*- mode: python; python-indent: 4 -*-
import ncs

from maagic_copy.maagic_copy import maagic_copy


if __name__ == '__main__':
    import logging
    logging.basicConfig(level=logging.DEBUG)
    with ncs.maapi.single_write_trans('', 'system') as t:
        root = ncs.maagic.get_root(t)

        maagic_copy(root.a, root.b)
