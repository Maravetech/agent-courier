"""Shared native catalog fixtures; never read the real session directories."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

def make_fixture(root):
    codex, claude, state = root/'codex', root/'claude', root/'overlay'
    for folder in [codex, claude/'account'/'workspace', state]: folder.mkdir(parents=True, exist_ok=True)
    titles = {'00172':'投递小鸟浮层 X4','00166':'值守测试','00159':'已归档会话','00173':''}
    (codex/'session_index.jsonl').write_text('\n'.join(json.dumps(dict(id=k,thread_name=k+' '+v)) for k,v in titles.items()))
    with sqlite3.connect(codex/'state_5.sqlite') as db:
        db.execute('CREATE TABLE threads(id TEXT, archived INTEGER)')
        db.executemany('INSERT INTO threads VALUES (?,?)',[(k,int(k=='00159')) for k in titles])
    (claude/'account'/'workspace'/'local_102.json').write_text(json.dumps(dict(title='0102 投递功能小鸟指示器',isArchived=False)))
    pairs=[]
    for app,a,b in [('Claude Code','0102','00172'),('Claude Code','0102','00166'),('Claude Code','0102','00173'),('Codex','00159','00172'),('Claude Code','0064','00172')]:
        pairs.append(dict(from_app=app,**{'from':a},to_app='Codex',to=b,state='replied',updated_at=1794050000,reason='preserve'))
    (state/'config.json').write_text('{"enabled":true}')
    (state/'pairs.json').write_text(json.dumps({'pairs':pairs,'version':1}))
    (state/'links.json').write_text(json.dumps({'disconnected':['Codex·00159→Codex·00172','Claude Code·0102→Codex·00166']}))
    env = dict(os.environ,CODEX_HOME=str(codex),COURIER_CLAUDE_SESSIONS=str(claude),COURIER_STATE_DIR=str(root))
    env.pop("COURIER_OVERLAY", None)
    return env

@unittest.skipUnless(sys.platform == "darwin", "macOS Swift overlay")
class PairDirectoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory(); p=Path(cls.build.name)
        (p/'main.swift').write_text('''import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.contains("--clean") { PairDirectory.clean(url, keys: CommandLine.arguments.count > 3 ? [CommandLine.arguments[3]] : PairDirectory.load(url).invalidKeys) }
let data = try JSONEncoder().encode(PairDirectory.load(url))
print(String(decoding:data,as:UTF8.self))
''')
        cls.binary=p/'catalog'
        subprocess.run(['swiftc',str(ROOT/'overlay/PairDirectory.swift'),str(p/'main.swift'),'-o',str(cls.binary)],check=True,capture_output=True)
    @classmethod
    def tearDownClass(cls): cls.build.cleanup()
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.env=make_fixture(self.root)
    def tearDown(self):self.temp.cleanup()
    def read(self,*args):
        return json.loads(subprocess.check_output([str(self.binary),str(self.root/'overlay/pairs.json'),*args],env=self.env,text=True))
    def test_groups_multi_pair_archived_deleted_and_title_missing(self):
        data=self.read();self.assertEqual((data['apps'],data['sessions'],data['invalid'],data['displayed']),(2,4,2,3))
        self.assertEqual(len([r for r in data['rows'] if r['app']=='Claude Code' and r['number']=='0102']),3)
        self.assertTrue(any('已归档' in r['reason'] for r in data['rows']))
        self.assertTrue(any('0064 不在会话列表' in r['reason'] for r in data['rows']))
        self.assertTrue(any(r['number']=='00173' and r['title']=='' and not r['invalid'] for r in data['rows']))
    def test_unreadable_index_is_unknown(self):
        (self.root/'codex/session_index.jsonl').unlink()
        (self.root/'claude/account/workspace/local_102.json').write_text('{broken')
        self.assertEqual(self.read()['invalid'],0)
    def test_index_keeps_latest_matching_row_after_malformed_and_unrelated_rows(self):
        index = self.root/'codex/session_index.jsonl'
        with index.open('a') as stream:
            stream.write('\n{broken}\n\n')
            for i in range(200):
                stream.write(json.dumps(dict(id=str(i), thread_name=f'{50000+i} Unrelated'))+'\n')
            stream.write(json.dumps(dict(id='00172', thread_name='00172 New title')))
        data = self.read()
        self.assertTrue(all(row['title'] == 'New title' for row in data['rows'] if row['number'] == '00172'))
        self.assertEqual(data['invalid'],2)

    def test_cleanup_only_invalid_pairs_and_links(self):
        self.read('--clean')
        body=json.loads((self.root/'overlay/pairs.json').read_text())
        self.assertEqual(len(body['pairs']),3);self.assertEqual(body['version'],1)
        self.assertTrue(all(r['reason']=='preserve' for r in body['pairs']))
        self.assertEqual(json.loads((self.root/'overlay/links.json').read_text())['disconnected'],['Claude Code·0102→Codex·00166'])
    def test_visibility_switch(self):
        (self.root/'overlay/config.json').write_text('{"enabled":false}')
        self.assertEqual(self.read()['displayed'],0)

    def test_single_cleanup_leaves_other_invalid_pair(self):
        self.read('--clean','Codex·00159→Codex·00172')
        self.assertEqual(self.read()['invalid'],1)
        self.assertEqual(len(json.loads((self.root/'overlay/pairs.json').read_text())['pairs']),4)
