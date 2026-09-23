import commerceLens from '@/assets/projects/commerce-lens.png'
import mypi from '@/assets/projects/mypi.png'
import pharmascope from '@/assets/projects/pharmascope.png'
import zhigenews from '@/assets/projects/zhigenews.png'

// Project details and screenshots come from docs/aboutme/aboutme.md.
export const projects = [
  {
    slug: 'zhigenews',
    name: '知更',
    label: 'ZHIGENEWS',
    description: '个性化新闻简报',
    url: 'https://zhigenews.zimagent.top/',
    image: zhigenews
  },
  {
    slug: 'bizsentinel',
    name: '商脉',
    label: 'COMMERCELENS',
    description: '电商经营分析与异常诊断',
    url: 'https://bizsentinel.zimagent.top/',
    image: commerceLens
  },
  {
    slug: 'mypi',
    name: 'MyPI',
    label: 'MYPI',
    description: '把想法写成可运行的代码',
    url: 'https://mypi.zimagent.top',
    image: mypi
  },
  {
    slug: 'pharmascope',
    name: 'PharmaScope',
    label: 'PHARMASCOPE',
    description: '医药研发情报追踪',
    url: 'https://pharmascope.zimagent.top',
    image: pharmascope
  }
]
