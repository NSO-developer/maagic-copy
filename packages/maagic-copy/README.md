# Maagic copy

## Description
Copy values of leaves under a to leaves under b. Will recursively call
ourself for encountered lists and containers.

Care should be taken when using this function for performing service-to-service copy,
where the source and target nodes are both service models. These contain a lot of internal
meta-data NCS structures that must not be copied. The service_copy flag is used to control
this behaviour. When set to True, nodes listed in the service_model_blacklist list will be
skipped.

The underlying MAAPI transaction of the destination maagic node is also temporarily modified
to postpone when statement evaluations. The original state is restored before exiting.

Note: in code, it is usually always a good idea to postpone "when" statement
evaluations until the VALIDATE transaction phase (typically when calling
trans.apply()). This can be done with the `maapi.set_delayed_when(1)` method.
The method is also proxied via the `ncs.maapi.Transaction` object.

## Usage
def maagic_copy(a, b, service_copy=True, _is_first=True):

:param a: source MAAGIC node
:param b: destination MAAGIC node
:param service_copy: if a copy is service model to service model, ignore NCS internal structures
:param _is_first: internal, for setting MAAPI flags on the first level of recursion