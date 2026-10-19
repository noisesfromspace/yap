// Package turn is the agent loop: it runs one turn — validating and
// serializing the request, streaming generation steps, executing tool calls
// (compiled-in tools from the tools package), and re-sending until the final
// answer or the iteration bound. Turns may share a long-lived process.
//
// The frontend wire protocol and its frames live in agent/wire; the loop here
// only emits into it. Mid-turn injections (steer, model switch, cancel) are
// delivered to Run through a poll callback and a context.
package turn
