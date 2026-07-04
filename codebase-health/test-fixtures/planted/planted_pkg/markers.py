"""Marker fixture. PLANTS A1-A6: every marker style the grep must catch."""


def sync_users():
    # TODO: wire up the retry path        <- PLANT A1: classic uppercase TODO
    # todo: also handle pagination         <- PLANT A2: LOWERCASE todo (case-insensitivity check)
    # We only sync the first page for now  <- PLANT A3: "for now" (taxonomy marker the old grep missed)
    # WIP - do not rely on this yet        <- PLANT A4: WIP
    # TBD: batch size                      <- PLANT A5: TBD
    return None


def make_report():
    # PLACEHOLDER until the real template lands  <- PLANT A6: PLACEHOLDER
    raise NotImplementedError("report generation")  # PLANT A7: NotImplementedError in concrete function
