from scrapling.parser import Selector

from subtitle_catalog import matches_movie_title, page_links, provider_url


def test_nested_title_and_provider_access_boundary():
    page = Selector(b'<a href="/subs/test.html"><b>The Prince</b> 2014</a>')
    link, = page_links(page)
    assert matches_movie_title(link['text'], 'The Prince', 2014)
    assert provider_url('https://www.subtitlecat.com/subs/test.html')
    assert not provider_url('https://www.subtitlecat.com:8443/subs/test.html')
    assert not provider_url('https://www.subtitlecat.com@another.example/test')
