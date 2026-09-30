$CK = (Send-Billing @{ user_id = 'carol'; plan = 'dev-basic' }).key
Test-ChatCode $CK chat-fast; Test-ChatCode $CK chat-smart     # 200 · 401/403
$CK2 = (Send-Billing @{ user_id = 'carol'; plan = 'dev-pro' }).key
Test-ChatCode $CK chat-fast                                    # 401 (key เดิมถูก block)
Test-ChatCode $CK2 chat-smart                                  # 200