import requests, urllib.parse
from bs4 import BeautifulSoup
q = "Foxeer Razer Mini V3 FPV Camera FOV"
url = "https://duckduckgo.com/html/?q=" + urllib.parse.quote(q)
text = requests.get(url, timeout=30, headers={"User-Agent":"Mozilla/5.0"}).text
soup = BeautifulSoup(text, "html.parser")
for a in soup.select("a.result__a")[:12]:
    print(a.get_text(" ", strip=True))
    print(a.get("href"))
    print("---")
