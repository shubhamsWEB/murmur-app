---
name: online-shopping
description: Shopping research - is this a good price, where to buy it, which of these to get, is this shop trustworthy. Research only; never buys.
triggers: [buy, buying, shop, shopping, cheapest, deal, deals, discount, flipkart, amazon, myntra, price, prices, kharidna, sasta]
source: adapted for Murmur from David Ondrej's online-shopping skill (MIT), github.com/davidondrej/skills
---

# Online shopping research

Research only. Never add to cart, place an order, sign in, create an account, or enter payment, address or tax
details: tell the user where to do it.

1. Pin down the exact item (model, size, variant) and what matters to the user (price, delivery, brand). Infer
   from what's on screen or said; ask one short question only if the answer would change.
2. Scale the effort to the price:
   - Cheap or obvious: answer from what's on screen and one quick search.
   - Mid-range: site_search two or three big shops (Amazon, Flipkart, the brand's own store, or what fits the
     user's country), open the listings, compare the same variant.
   - Expensive: also read reviews (a trusted review site or the listing's reviews) and check warranty and seller.
3. Check the shop: an unknown site with a price far below everyone else, no company details, fake urgency or
   long shipping from a "local" store is a warning sign. Prefer the brand's store or a big marketplace's own
   seller.

## The answer
A bold verdict first (good deal, fair, or overpriced) with the fair price range. Then the best two or three places
to buy with their prices, as found. Mention delivery time or seller only when it decides things. Only prices you
actually saw; label anything estimated.
