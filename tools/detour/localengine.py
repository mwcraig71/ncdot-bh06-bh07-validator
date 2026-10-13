"""Point the measurement prototype at the local North Carolina graph.
The prototype speaks Valhalla's HTTP JSON; the local Actor speaks the same
JSON in-process, so only the transport changes."""
import io, json, sys, urllib.error
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import detour_probe as dp
from valhalla import Actor
ACTOR = Actor(os.environ.get('VALHALLA_CONFIG', 'valhalla.json'))
def _post(path, body):
    fn = {'/route': ACTOR.route, '/locate': ACTOR.locate}[path]
    try:
        return json.loads(fn(json.dumps(body)))
    except RuntimeError as ex:
        msg = str(ex).encode()
        raise urllib.error.HTTPError(path, 400, str(ex), {}, io.BytesIO(msg))
def use_local():  dp.post = _post
