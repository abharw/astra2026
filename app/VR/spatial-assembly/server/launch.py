import getpass,os,subprocess
key=os.environ.get('OPENAI_API_KEY') or getpass.getpass('OpenAI API key (hidden, memory only): ')
if not key:raise SystemExit('No key provided')
env=os.environ.copy();env['OPENAI_API_KEY']=key
raise SystemExit(subprocess.call(['node','server.mjs'],env=env,cwd=os.path.dirname(os.path.abspath(__file__))))
