import { expandTimeline } from './timelines';

export function expandMemories(params = {}) {
  return expandTimeline('memories', 'api/v1/memories', params);
}
