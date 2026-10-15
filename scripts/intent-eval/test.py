# Held-out sentences, written separately from the training ones (other names, apps, phrasings), plus real commands
# from Murmur's log (marked REAL). (label, text).
D = "dictation"
TEST = [
# ---------- dictation ----------
(D, "Neha, can you share the Figma link with me before lunch"),
(D, "I'm stuck in a meeting, will call you back in an hour"),
(D, "Please open the attachment and confirm the numbers by EOD"),
(D, "Find a quiet corner in the cafe, I'll join you soon"),
(D, "The volume knob on the speaker is broken"),
(D, "Let me know once you send the payment"),
(D, "Search results look better after the last deploy"),
(D, "Delete the old branch after merging, it's confusing everyone"),
(D, "We played really well in the second half"),
(D, "Hi Vikram, the PDF looks good, just fix the logo on page 2"),
(D, "Can we do the review on Telegram instead"),
(D, "Remember when we went to Coorg last year"),
(D, "Take your time, no rush on this"),
(D, "Message me the OTP once it comes"),
(D, "Open office hours are on Thursday from 3 to 5"),
(D, "Thanks Arjun, the screenshots helped a lot"),
(D, "What do you think about moving to Notion"),
(D, "Lock in the price before it goes up"),
(D, "Switch the cake order to chocolate please"),
(D, "Kindly approve the leave request for next Monday"),
(D, "arre kal toh holiday hai na"),
(D, "main abhi meeting mein hoon, baad mein call karta hoon"),
(D, "Neha ko bol dena main file bhej dunga"),
(D, "photos bhej do trip ki"),
(D, "bhai Spotify ka premium le liya kya"),
(D, "kya hum Sunday ko mil sakte hain"),
(D, "mujhe lagta hai price thoda zyada hai"),
(D, "office ka wifi bahut slow hai aaj"),
(D, "kal subah 9 baje call karte hain"),
(D, "maine report dekh li, sab theek hai"),
(D, "aaj khana bahar khayenge"),
(D, "usne WhatsApp pe kuch bheja tha kya"),
(D, "please meri leave approve kar dena"),
(D, "बहुत बढ़िया काम किया तुमने"),
(D, "कल ऑफिस नहीं आ पाऊँगा"),
# ---------- open_app ----------
("open_app", "Open Figma"),
("open_app", "Launch Notion"),
("open_app", "Quit Microsoft Teams"),
("open_app", "Switch to Safari"),
("open_app", "Close Telegram"),
("open_app", "Open Anti-Gravity"),   # REAL-ish (app)
("open_app", "Figma kholo"),
("open_app", "Teams band karo"),
("open_app", "Notion open kar do"),
("open_app", "Safari khol de bhai"),
("open_app", "Telegram chalu karo"),
# ---------- open_file ----------
("open_file", "Mera PAN card kholo."),                    # REAL
("open_file", "Mera aadhaar card kholo."),                # REAL
("open_file", "Mera driving license kholo."),             # REAL
("open_file", "Mera resume kholo mere files se."),        # REAL
("open_file", "Open my PAN card."),                       # REAL
("open_file", "Phir se try karo aur aadhaar card kholo."),# REAL
("open_file", "Open the rental agreement"),
("open_file", "Open my CV"),
("open_file", "Open the Figma export of the logo"),
("open_file", "Open the salary slip for September"),
("open_file", "meri marksheet kholo"),
("open_file", "insurance policy ki PDF dikhao"),
("open_file", "voter ID khol do"),
# ---------- search_files ----------
("search_files", "Find photos from Coorg"),
("search_files", "Search for invoices from Amazon"),
("search_files", "Look for the PDF about home loans"),
("search_files", "Find videos of the birthday party"),
("search_files", "Show me screenshots of error messages"),
("search_files", "Coorg trip ki photos dhundo"),
("search_files", "home loan wale PDF search karo"),
("search_files", "birthday party ke videos dikhao"),
("search_files", "Amazon ke invoices kahan hain"),
# ---------- message ----------
("message", "Send a message to Roma High."),               # REAL
("message", "Send a message to Roma Hi."),                 # REAL
("message", "Send a hot message to Roma and WhatsApp"),    # REAL
("message", "Send a heart emoji to Roma on WhatsApp"),     # REAL
("message", "Message Neha on Telegram that I'm running late"),
("message", "Text Vikram happy anniversary"),
("message", "WhatsApp Arjun the meeting link"),
("message", "Tell the team on Teams that I'm off tomorrow"),
("message", "Send Neha a message saying call me"),
("message", "Mama ko message karo ki main late hoon"),
("message", "Neha ko WhatsApp pe hi bolo"),
("message", "Vikram ko Telegram pe bhejo ki kal milte hain"),
("message", "bhaiya ko text kar do ki gaadi le aaye"),
("message", "Arjun ko bol do ki call kare"),
# ---------- system ----------
("system", "Set volume to 20"),
("system", "Unmute"),
("system", "Turn on Bluetooth"),
("system", "Dim the screen"),
("system", "Disable Wi-Fi"),
("system", "Open battery settings"),
("system", "awaaz badha do"),
("system", "bluetooth on karo"),
("system", "wifi band kar do"),
("system", "screen ki brightness badhao"),
# ---------- media ----------
("media", "Pause"),
("media", "Play the next video"),
("media", "Resume"),
("media", "Skip"),
("media", "Play some jazz on Apple Music"),
("media", "video roko"),
("media", "gaana chalao"),
("media", "agla video chalao"),
# ---------- web ----------
("web", "Open LinkedIn"),
("web", "Search Google for flights to Delhi"),
("web", "Go to news.ycombinator.com"),
("web", "Find running shoes on Flipkart"),
("web", "Search YouTube for Swift tutorials"),
("web", "LinkedIn kholo"),
("web", "Flipkart pe running shoes dhundo"),
("web", "YouTube pe Swift tutorial search karo"),
# ---------- screen ----------
("screen", "Summarize this article"),
("screen", "What am I looking at"),
("screen", "Explain this code"),
("screen", "Make this sound friendlier"),
("screen", "Translate this into English"),
("screen", "ye article ka summary batao"),
("screen", "ye code samjhao"),
("screen", "isko English mein translate kar do"),
# ---------- task ----------
("task", "Open my email and summarize all the imported emails."),  # REAL (ASR slip)
("task", "Open the Unread hostinger email and give me the details."),  # REAL
("task", "Open Murmur repository in Anti-Gravity."),                    # REAL
("task", "Go through my WhatsApp chats and tell me who needs a reply"),
("task", "Check my unread Slack messages and summarise them"),
("task", "Find the cheapest flight to Delhi on Google and open it"),
("task", "Read my emails from today and list the action items"),
("task", "Roma ki WhatsApp chat padh ke batao aaj kya baat hui"),
("task", "saare unread mails padh ke important wale batao"),
("task", "Flipkart pe shoes dhundo aur sabse sasta wala kholo"),
# ---------- memory ----------
("memory", "Marmar mera naam shubham hai."),             # REAL (ASR slip)
("memory", "Remember that Neha is my sister"),
("memory", "From now on use Safari for links"),
("memory", "Forget what I told you about Mama"),
("memory", "yaad rakhna Neha meri behen hai"),
("memory", "aage se Safari use karna"),
# ---------- question ----------
("question", "What's on my calendar this week"),
("question", "How much storage do I have left"),
("question", "Any meetings this afternoon"),
("question", "What did I message Neha yesterday"),
("question", "is hafte calendar mein kya hai"),
("question", "Mac mein kitna storage bacha hai"),
]
