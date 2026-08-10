# This example wires every input inline in main.tf; no pass-through variables
# are needed. Sensitive values such as the Teleport join token are supplied at
# runtime via TF_VAR_* environment variables rather than declared here.
