# SPDX-FileCopyrightText: 2023 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Tests tagged `:library_bug` pin defects that are known and not yet fixed: each
# asserts the behaviour the library SHOULD have, so it goes green when its fix
# lands (then drop the tag). They are excluded from an ordinary run so that `mix
# test` reports on the code under review, not on the backlog; run them with
# `mix test --include library_bug`.
ExUnit.start(exclude: [:library_bug])
