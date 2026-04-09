# YouTube Script — Load Balancing LLM Models with AgentGateway

## INTRO

Hey everyone, welcome back. I'm Sebastian Maniak from Solo.io.

So here's the problem -- if you're building anything with LLMs today, you're probably locked into a single provider. One API key, one model, one point of failure. And when that provider has an outage, or you hit a rate limit, or you just want to compare how Claude stacks up against GPT on your actual production traffic -- you're stuck writing custom routing logic in your application code.

Today I'm going to show you how to solve that with AgentGateway. We're going to do two things:

**First**, we'll set up multi-provider load balancing -- OpenAI and Anthropic behind a single endpoint. AgentGateway uses an algorithm called Power of Two Choices, or P2C, which is smarter than simple round-robin. It picks two providers, checks their health, latency, and current load, and routes to whichever one scores better. So you get automatic failover and intelligent distribution without touching your app code.

**Second**, once we've seen that working, we'll set up A/B traffic splitting -- 80% of requests going to GPT-4o as the stable production model, 20% to GPT-4o-mini as a canary. This is just standard Gateway API weighted routing. No proprietary annotations, no SDK changes.

Everything runs locally on a kind cluster. All the code is in the repo linked in the description. Let's get into it.

---

## OUTRO

And that's it. Let me recap what we just did.

We deployed AgentGateway on a local kind cluster, pointed it at both OpenAI and Anthropic, and with a single YAML we got intelligent load balancing across both providers. We sent requests to `/chat` and saw them distributed between GPT-4o and Claude based on real-time health and latency scoring -- not static weights, not round-robin.

Then we set up A/B testing with two separate backends and an 80/20 weighted HTTPRoute. Standard Gateway API. You saw roughly 8 out of 10 requests hitting the stable model and 2 hitting the canary -- exactly what you'd use to evaluate a new model in production before committing to a full rollout.

Four things to take away:

**One** -- P2C is smarter than round-robin. It adapts to what's actually happening with your providers in real time.

**Two** -- multi-provider routing is one YAML away. Put providers in the same group, AgentGateway handles the rest.

**Three** -- A/B testing uses standard Gateway API weighted backend refs. Nothing proprietary.

**Four** -- everything we did here runs on a local kind cluster. You can clone the repo, set your API keys, and have this running in about five minutes.

All the code, the step-by-step guide, and the manual commands are in the repo linked below. If you want to try this yourself, everything's there.

If this was useful, hit subscribe -- I've got more AgentGateway demos coming. Thanks for watching.
