
import contextlib
from functools import wraps
from typing import Union

import ncs
import _ncs


def hack_get_maagic_full_python_name(target_container: ncs.maagic.Container,
                                     node_name: str) -> str:
    """Get the fully qualified python maagic node name within the target
    namespace.

    :param target_container: target maagic.Node (container / list entry)
    :param node_name: child node name
    :return: string name of node namespace__name

    Sometimes when using the MAAGIC API, you need to know the fully
    qualified name of the node, including the prefix, like ts__class.
    This happens if the node name is a reserved keyword, or would
    collide with some other attribute. The evaluation is performed at
    runtime by the MAAGIC API.
    """
    target_prefix = _ncs.ns2prefix(target_container._cs_node.ns()) # pylint: disable=no-member
    return target_container._children.full_python_name(target_prefix, str(node_name))

def path_to_xpath(node_or_path: Union[str, ncs.maagic.Node]) -> str:
    """Get the XPath to a node (keypath or maagic Node)

    The input can be either:
    - string keypath (/devices/device{foo}/config/alu:port...),
    - maagic Node instance.
    The helper will start a new MAAPI read transaction if necessary.

    :param node_or_path: string keypath or Node instance
    :returns: a string XPath to the node
    """
    with contextlib.ExitStack() as stack:
        if isinstance(node_or_path, str):
            # for a string input, we need a MAAPI session and read transaction
            t_read = stack.enter_context(ncs.maapi.single_read_trans('python-path-to-xpath', 'system'))
            t_read.pushd(node_or_path)
        elif isinstance(node_or_path, ncs.maagic.Node):
            # for a Node input, we first attempt to retrieve the backend transaction
            try:
                t_read = ncs.maagic.get_trans(node_or_path)
            except ncs.maagic.BackendError:
                try:
                    # if there is no backend transaction, try to get the backend MAAPI
                    # and start a new transaction
                    maapi = ncs.maagic.get_maapi(node_or_path)
                    t_read = stack.enter_context(maapi.start_read_trans())
                except ncs.maagic.BackendError:
                    # if the node has no compatible backend, we're back to square one
                    # and need to set up MAAPI and read transaction
                    t_read = stack.enter_context(ncs.maapi.single_read_trans('python-path-to-xpath', 'system'))
            t_read.pushd(node_or_path._path)
        xpath = _ncs.xpath_pp_kpath(t_read.getcwd_kpath())  # pylint: disable=no-member
        t_read.popd()
    return xpath

def _maagic_copy_wrapper(fn):
    """Wrapper for the maagic_copy function, changes input maagic node and tracks recursion depth

    The first argument to the maagic_copy function (source maagic node) will be replaced by
    a maagic node referring to the same node in the data tree, but with a nested transaction
    using a FLAG_NO_DEFAULTS MAAPI flag.
    """

    @wraps(fn)
    def wrapper(a, b, service_copy=True, _is_first=True):
        if _is_first:
            # When maagic_copy is on the first level of recursion, set MAAPI flag to allow us
            # explicit default value detection with a `C_DEFAULT` value.
            # This is done by:
            #  1. starting a nested transaction using a's maagic object transaction,
            #  2. setting the MAAPI flag in nested transaction,
            #  3. replacing a with a new maagic object backed by the nested transaction

            src_trans = ncs.maagic.get_trans(a)
            with src_trans.start_trans_in_trans(ncs.READ) as src_tt:
                src_tt.set_flags(_ncs.maapi.FLAG_NO_DEFAULTS)
                a_tt = ncs.maagic.get_node(src_tt, a._path)
                return fn(a_tt, b, service_copy, _is_first=True)
        else:
            return fn(a, b, service_copy, _is_first=False)
    return wrapper


@_maagic_copy_wrapper
def maagic_copy(a, b, service_copy=True, _is_first=True):
    """ Copy values of leaves under a to leaves under b. Will recursively call
        ourself for encountered lists and containers.

        Care should be taken when using this function for performing service-to-service copy,
        where the source and target nodes are both service models. These contain a lot of internal
        meta-data NCS structures that must not be copied. The service_copy flag is used to control
        this behaviour. When set to True, nodes listed in the service_model_blacklist list will be
        skipped.

        :param a: source MAAGIC node
        :param b: destination MAAGIC node
        :param service_copy: if a copy is service model to service model, ignore NCS internal structures
        :param _is_first: internal, for setting MAAPI flags on the first level of recursion
    """

    # NCS internal nodes present in service models
    service_model_blacklist = [
        ('private', ncs.maagic.Container),                  # service-private-data
        ('modified', ncs.maagic.Container),                 # service-impacted-devices
        ('directly-modified', ncs.maagic.Container),        # service-impacted-devices
        ('device-list', ncs.maagic.LeafList),               # service-impacted-devices
        ('used-by-customer-service', ncs.maagic.LeafList),  # service-customer-service
        ('commit-queue', ncs.maagic.Container),             # service-commit-queue
        ('log', ncs.maagic.Container)                       # log-data
    ]

    if type(a) in (ncs.maagic.Case,                         # pylint: disable=unidiomatic-typecheck
                   ncs.maagic.Container,
                   ncs.maagic.PresenceContainer,
                   ncs.maagic.ListElement,
                   ncs.maagic.ActionParams):
        # we will use an internal Node._children ChildList to get the source & target maagic Nodes.
        # we need to make sure a and b are populated. a is populated via dir(a)
        if not b._populated:
            b._populate()

        # do not overwrite List keys on target. failure to do so leads to weird changes detection
        if isinstance(b, ncs.maagic.ListElement):
            list_keys = [child for child in dir(b)
                         if not child.startswith('__') and b._children[child]._cs_node.is_key()]
        else:
            list_keys = []

        for attr_name in dir(a):
            if attr_name.startswith('__') or attr_name in list_keys:
                continue

            src_node = a._children[attr_name]

            if isinstance(src_node, ncs.maagic.Action):
                continue

            # on the first level, skip NCS internal service model nodes
            if service_copy and _is_first:
                if (src_node._name, type(src_node)) in service_model_blacklist:
                    continue

            try:
                dst_node = b._children[attr_name]
            except KeyError:
                # the node likely doesn't exist on the target, except if it has a different
                # Python name because of a forbidden word.
                # for example leaf 'class' will be accessible via 'prefix__class' in Python,
                # but the prefix can change if the target is defined in a different module
                if '__' in attr_name:
                    # assume the target node has the same namespace as the parent
                    attr_name = hack_get_maagic_full_python_name(b, src_node)
                    try:
                        dst_node = b._children[attr_name]
                    except KeyError:
                        # just skip to next one if destination doesn't exist
                        continue
                else:
                    continue

            # now that we have a src_node and dst_node, we make sure their _path attributes are
            # populated correctly. again, since we used the internal `_children` ChildList, we do
            # that ourselves ...
            unpopulated = (node for node in (src_node, dst_node) if not node._populated)
            for node in unpopulated:
                node._populate()

            if isinstance(src_node, (ncs.maagic.Container,
                                     ncs.maagic.List,
                                     ncs.maagic.ListElement,
                                     ncs.maagic.LeafList)):
                # if the source container is a presence container, create
                # destination conditionally
                if isinstance(src_node, ncs.maagic.PresenceContainer):
                    # check if presence container is present in data tree
                    if src_node.exists():
                        if isinstance(dst_node, ncs.maagic.PresenceContainer):
                            dst_node.create()
                    else:
                        try:
                            dst_node.delete()
                        except _ncs.error.Error as e:
                            if 'item does not exist' not in str(e):
                                raise
                        continue
                # if only the destination container is a presence container,
                # create it unconditionally
                elif isinstance(dst_node, ncs.maagic.PresenceContainer):
                    dst_node.create()
                maagic_copy(src_node, dst_node, _is_first=False)
            elif isinstance(src_node, ncs.maagic.Choice):
                # No need to copy the choice itself as it follows implicitly from the present case children
                pass

            elif isinstance(src_node, ncs.maagic.NonEmptyLeaf):
                try:
                    # make sure we're not getting a cached value after changing FLAG_NO_DEFAULTS
                    src_node.update_cache(force=True)

                    # Leaf.get_value_object() returns a _ncs.Value object, which will have
                    # type C_DEFAULT iff the leaf is empty (=serving default).
                    val = src_node.get_value_object()
                    if val and val.confd_type() == ncs.C_DEFAULT:
                        # The source leaf is empty. If destination has a different or no default
                        # value, we take the default value form the source leaf and explicitly
                        # write to destination

                        # first check if the destination leaf has a default at all
                        src_default = src_node._cs_node.info().defval()
                        dst_default = dst_node._cs_node.info().defval()
                        if dst_default is not None and src_default == dst_default:
                            # both leaves have the same default, we remove destination value
                            dst_node.delete()
                            continue
                        else:
                            # destination has a different default value or not a default leaf,
                            # need to copy source explicitly
                            dst_node.set_value(src_default)
                            continue
                    dst_node.set_value(src_node.get_value())
                except Exception:
                    pass
                    # if destination leaf doesn't exist, just silently ignore,
                    # we do copy on a best-effort basis, if the source and
                    # destination YANG models aren't equivalent we can't do
                    # anything about that
            elif isinstance(src_node, ncs.maagic.EmptyLeaf):
                # create / remove the 'empty' type leaf
                if src_node.exists():
                    dst_node.create()
                else:
                    # trying to .delete() a non-existing empty leaf will fail
                    if dst_node.exists():
                        dst_node.delete()
            else:
                # it is best to raise an exception here if we encounter an unknown type,
                # rather than silently eating the error and not copying the data
                raise TypeError('{}: Unknown source type {}'
                                .format(src_node._path, type(src_node)))
    elif isinstance(a, ncs.maagic.List):
        # loop over ListElement in List

        # Find out keys from schema to handle combinations of cdb/in-memory and keyed/non-keyed
        key_names = [_ncs.hash2str(h) for h in b._cs_node.info().keys() or []]  # pylint: disable=no-member
        for src_le in a:
            keys = [src_le[k] for k in key_names]
            dst_le = b.create(*keys)
            # recursively invoke ourself to copy source ListElement to
            # destination
            maagic_copy(src_le, dst_le, _is_first=False)
    elif isinstance(a, ncs.maagic.LeafList):
        # the target leaf-list is replaced with the source. first, remove
        # all entries from the target.
        b.delete()

        # Most leaf-lists can be copied as python lists,
        # like `b.set_value(a.as_list())`.
        # If the leaf-list is of type instance-identifier, we need to work
        # around some inconsistencies in the NSO MAAGIC API.
        # Reading an instance-identifier type leaf will yield an
        # HKeypathRef object.
        # The same object cannot be used to write the value to the leaf -
        # the written value *must* be an XPath string.
        for c in a:
            # Change key path string to XPath to work around the problem of
            # leaf-list creating instance-identifier item
            if isinstance(c, _ncs.HKeypathRef): # pylint: disable=no-member#
                b.create(path_to_xpath(str(c)))
            else:
                b.set_value(a.as_list())
                break
    else:
        raise ValueError("Can't copy leaf to leaf. {} ({})".format(a, type(a)))
        # we can't do this because we aren't actually passed the leaves but the
        # values of the leaves
