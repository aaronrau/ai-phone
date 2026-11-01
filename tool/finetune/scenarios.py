"""Call scenarios for generating decision-model training dialogues.

Compiled from public consumer-protection guidance (FTC, FCC, SSA OIG, IRS,
Medicare, CFPB, FBI IC3, BBB, AARP), checked 2026-10-31. Only descriptions are
given to the generator; the literal example lines used for evaluation live in
test/fixtures/decision_eval_v2.jsonl and are never shown to it.

Each scenario says how a caller behaves over a few turns and which action the
receptionist should take at each point:
  clarify  - intent or objective not clear yet: ask a follow-up question
  identify - caller said who they are and a legitimate reason
  message  - wants to leave (or is dictating) a message / a call back
  availability - asks when the owner is free (known contacts only)
  spam     - selling, asking for money/payment, asking the caller to do
             something (press a key, read a code, install, verify details),
             threats, prizes, impersonation with demands
  goodbye  - ending the call
  other    - off-topic question or small talk aimed at the assistant
"""

SCAMS = [
    ('irs_threat', 'Impersonates the IRS or a tax agent: lawsuit, arrest or police threat, demands immediate payment by '
     'gift card, prepaid card or wire, asks for SSN or date of birth.', 'spam from the first line when it threatens '
     'arrest or says press 1; otherwise one clarify, then spam when payment or threats appear'),
    ('tax_relief', 'Robocall or telemarketer offering tax debt relief, a government "fresh start" program, upfront fee.',
     'spam'),
    ('ssa_suspended', 'Claims the Social Security number is suspended or linked to a crime, reads a fake badge number, '
     'asks to move money to a safe account, gold or crypto, demands secrecy.', 'spam'),
    ('medicare', 'Offers a new Medicare card, a free back brace or genetic test kit, asks for the Medicare number, date '
     'of birth or doctor name.', 'spam'),
    ('bank_safe_account', 'Claims to be the bank fraud department; after a follow-up question asks for the full card '
     'number, PIN, password or one-time code, or to move money to a secure account, or refuses a call back on the '
     'number on the card.', 'clarify first (real banks also call), spam once codes, PINs or moving money come up'),
    ('otp_code', 'Phone carrier, Google Voice or bank "support" asking the receptionist to read back a verification '
     'code that was just texted.', 'spam as soon as a code is requested'),
    ('boss_gift_cards', 'Pretends to be the owner\'s manager or IT help desk; urgent favor to buy gift cards or reset '
     'MFA with a code; text only, cannot talk.', 'clarify first, spam once gift cards, codes or passwords come up'),
    ('tech_support', 'Microsoft, Apple or antivirus "support": computer hacked, renewal charge, wants remote access or a '
     'website install, refund overpayment.', 'spam'),
    ('utility_shutoff', 'Power or gas will be shut off within the hour unless paid now by prepaid card, payment app or '
     'crypto kiosk.', 'spam'),
    ('package_customs', 'Robocall about an undeliverable package with a small redelivery fee, or customs seized a '
     'package with illegal items and transfers to "police".', 'spam'),
    ('amazon_order', 'Amazon, PayPal or Walmart "fraud team" about an expensive order or auto-renewal; asks for login '
     'or card or to install an app.', 'spam'),
    ('car_warranty', 'Vehicle extended warranty expiring, final courtesy call, down payment today.', 'spam'),
    ('student_loan', 'Student loan forgiveness "processing center"; needs the FSA ID, a processing fee, or payments '
     'redirected to them.', 'spam'),
    ('card_services', '"Card services" lower interest rate or debt relief; asks for card balances and numbers and an '
     'enrollment fee.', 'spam'),
    ('prize', 'Sweepstakes, lottery or free cruise win; taxes or processing fee must be paid first, keep it secret.',
     'spam'),
    ('grandparent', 'Panicked relative or a "lawyer" says a family member was arrested or in an accident; needs bail '
     'money, cash courier or gift cards; do not tell anyone. Voice may sound like a relative.', 'clarify first '
     '(real relatives call from unknown numbers), spam once money, a courier or secrecy is requested'),
    ('jury_warrant', 'Sheriff or deputy says the owner missed jury duty and has a warrant; pay a bond by prepaid card '
     'or crypto kiosk and stay on the line.', 'spam'),
    ('agency_deactivation', 'FTC, FBI or police impersonator: the owner\'s phone number is linked to crime and will be '
     'deactivated; transfer to "police", deposit, secrecy.', 'spam'),
    ('charity', 'Charity or disaster relief donation, sometimes claims a past pledge; wants a card now, gift cards or a '
     'payment app; vague about where money goes.', 'clarify first, spam once payment by phone, gift cards or a fake '
     'pledge comes up'),
    ('crypto_investment', 'Guaranteed-return investment, AI trading program or gold IRA; deposit via crypto ATM; do '
     'not tell the bank.', 'spam'),
    ('romance', 'Someone the owner met online says the owner is not answering; stuck abroad, needs help with fees, or '
     'wants to teach a crypto platform.', 'clarify first, spam once money or crypto comes up'),
    ('job_scam', 'Recruiter offering a remote job with very high pay; hired without interview; wants bank details, an '
     'upfront training fee, or to move to WhatsApp or Telegram.', 'clarify first, spam once fees or bank details '
     'come up'),
    ('timeshare', 'Buyer found for the owner\'s timeshare; closing fee, transfer tax or escrow due first.', 'spam'),
    ('solar_home_warranty', 'Free solar panels through a "government program", home warranty reinstatement, or energy '
     'rebate; asks if they are the homeowner and for the utility account number.', 'spam'),
    ('can_you_hear_me', 'Opens with "can you hear me" or "is this the homeowner" before saying who they are; a '
     'recorded pitch or hang-up follows. Never answer yes.', 'clarify'),
    ('wangiri', 'A caller from an international number says "call me back urgently" and nothing else, or silence.',
     'clarify, then other or spam'),
    ('wrong_number_fishing', 'Says wrong number but keeps chatting, asks the receptionist\'s name and location, '
     'suggests WhatsApp, mentions investing.', 'clarify first, spam once they fish for personal details or pitch '
     'investing'),
    ('political_robocall', 'Prerecorded political poll or survey that offers a prize, or an AI celebrity voice.',
     'spam'),
    ('toll_fee', 'Unpaid toll balance with a late fee and license suspension threat; pay by phone or link.', 'spam'),
    ('recovery', 'A "recovery unit" or attorney offers to recover money the owner lost before; charges a fee or wants '
     'bank login.', 'spam'),
    ('fake_collector', 'Pre-legal department or process server threatens a lawsuit or warrant today unless the owner '
     'settles now by card or payment app; refuses to mail a validation notice.', 'spam'),
]

LEGIT = [
    ('pharmacy', 'Pharmacy says a prescription is ready or a refill is due; no payment requested.', 'identify'),
    ('clinic', 'Doctor or dentist office confirming or rescheduling an appointment.', 'identify'),
    ('real_bank_alert', 'Bank asks the owner to confirm a specific purchase or call the number on the back of the card; '
     'never asks for PIN, code or to move money, happy with a call back.', 'identify or message'),
    ('delivery_driver', 'Delivery driver at the door or gate asking where to leave a package.', 'identify'),
    ('school', 'School nurse or office: child is sick and needs pickup, or a schedule change.', 'identify or message'),
    ('contractor', 'Plumber, roofer or electrician returning the owner\'s call about a quote or job.', 'identify'),
    ('real_recruiter', 'Recruiter from a named company asking whether the owner is open to a quick chat; no fees.',
     'identify'),
    ('insurance_agent', 'Insurance agent following up on a quote the owner requested.', 'identify'),
    ('landlord', 'Landlord or property manager scheduling an inspection or repair.', 'identify'),
    ('utility_maintenance', 'Utility announcing planned maintenance or scheduling a meter upgrade; no payment.',
     'identify'),
    ('volunteer', 'Live volunteer from a campaign or neighborhood group the owner knows asking for help.', 'identify'),
    ('hospital_survey', 'The owner\'s hospital asking for a short survey about a recent visit; no prize.', 'identify'),
    ('debt_collector', 'Legitimate debt collector: gives name and company, asks the owner to call back about a '
     'personal business matter, no threats, will send a written notice.', 'identify or message'),
    ('family_new_number', 'Brother, aunt or friend calling from a borrowed or new phone, asks the owner to call back; '
     'no money requested.', 'identify or message'),
    ('honest_wrong_number', 'Caller realises they dialled the wrong number and apologises.', 'goodbye'),
    ('irs_collection_agency', 'IRS-contracted collection agency or revenue agent referencing a mailed notice, calm, '
     'asks for a call back.', 'identify'),
    ('medicare_plan', 'The owner\'s own Medicare plan or 1-800-MEDICARE returning the owner\'s call.', 'identify'),
    ('employer_hr', 'Employer HR reminding about benefits enrollment; asks the owner to log in to the portal later.',
     'identify'),
    ('dealer_recall', 'Car dealer about a free safety recall repair.', 'identify'),
    ('police_followup', 'Officer following up on a report the owner filed; asks for a call back on the non-emergency '
     'line.', 'identify'),
]

AMBIGUOUS = [
    ('is_owner_there', 'Asks whether the owner is there without saying who they are.'),
    ('hello_hello', 'Only says hello, or hello hello, maybe a bad connection.'),
    ('returning_call', 'Says they are returning a call, nothing more.'),
    ('about_account', 'Says it is about "your account" without naming the company.'),
    ('personal_matter', 'Says it is a personal matter and they can only speak to the owner.'),
    ('its_me', 'Says "hi it\'s me" as if they should be recognised.'),
    ('homeowner', 'Asks whether they are speaking to the homeowner.'),
    ('county_office', 'Says they are calling from the county or the city.'),
    ('delivery_vague', 'Says they have a delivery for the owner, nothing else.'),
    ('following_up_inquiry', 'Says they are following up on the owner\'s inquiry without naming it.'),
    ('good_time', 'Asks if this is a good time to talk.'),
    ('who_am_i_speaking_with', 'Asks who they are speaking with before saying anything.'),
    ('carrier', 'Says they are calling from the phone carrier.'),
    ('friend_from_work', 'Says they are a friend of the owner from work.'),
    ('about_the_claim', 'Says they are calling about "the claim".'),
]

KNOWN = [
    ('known_availability', 'A friend or relative asks when the owner is free, or about a specific day or time.',
     'availability'),
    ('known_message', 'A friend or relative asks to pass something on or for a call back.', 'message'),
    ('known_vague', 'A friend says hi or asks how the owner is doing without a clear request.', 'clarify'),
    ('known_goodbye', 'A friend says never mind, they will call back later.', 'goodbye'),
    ('known_offtopic', 'A friend asks the assistant something unrelated, like the weather or whether it is a robot.',
     'other'),
]
