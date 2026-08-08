-- ============================================
-- 001_initial_schema.sql
-- 初始化数据库架构
-- 
-- 📖 这是什么？
-- 这个文件创建了 App 最基础的数据库表
-- 包括：用户信息表、帖子表、图片表、收藏表
-- 
-- 🔧 如何使用？
-- 1. 登录 Supabase Dashboard
-- 2. 进入 SQL Editor
-- 3. 复制粘贴这个文件的内容
-- 4. 点击 Run 执行
-- 
-- ⚠️ 注意事项
-- - 这是第一个要执行的迁移文件
-- - 执行前确保数据库是空的
-- - 如果报错说表已存在，说明之前执行过了
-- ============================================

-- gen_random_uuid() 依赖 pgcrypto 扩展
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;


-- ============================================
-- 第一部分：用户信息表 (profiles)
-- ============================================
-- 
-- 🎯 这个表的作用：
-- Supabase 自带一个 auth.users 表存储登录信息（邮箱、密码等）
-- 但我们需要存储更多用户信息（头像、学校、昵称等）
-- 所以创建这个 profiles 表来扩展用户信息
-- 
-- 📝 表结构解释：
-- id         - 用户唯一标识，和 auth.users 的 id 一一对应
-- email      - 用户邮箱，不能重复
-- full_name  - 用户昵称/姓名
-- avatar_url - 头像图片的网址
-- university - 用户所在的学校
-- student_id - 学生证号（可选，用于认证）
-- verified   - 是否已经认证过
-- is_anonymous - 是否默认使用匿名模式发帖
-- created_at - 账号创建时间
-- updated_at - 最后更新时间

CREATE TABLE profiles (
  -- id 是主键（Primary Key），用来唯一标识每个用户
  -- UUID 是一种全球唯一的 ID 格式，比如 "550e8400-e29b-41d4-a716-446655440000"
  -- REFERENCES auth.users 表示这个 id 必须在 auth.users 表中存在
  -- ON DELETE CASCADE 表示如果用户被删除，这条记录也会自动删除
  id UUID REFERENCES auth.users ON DELETE CASCADE PRIMARY KEY,
  
  -- email 是文本类型，UNIQUE 表示不能有两个用户用同一个邮箱
  -- NOT NULL 表示这个字段必须填写，不能为空
  email TEXT UNIQUE NOT NULL,
  
  -- full_name 是用户昵称，可以为空（没有 NOT NULL）
  full_name TEXT,
  
  -- avatar_url 存储头像图片的 URL 地址
  avatar_url TEXT,
  
  -- university 是学校名称，必填
  university TEXT NOT NULL,
  
  -- student_id 学生证号，可选
  student_id TEXT,
  
  -- verified 表示是否已认证，默认是 FALSE（未认证）
  -- BOOLEAN 类型只有两个值：TRUE 或 FALSE
  verified BOOLEAN DEFAULT FALSE,
  
  -- is_anonymous 是否默认匿名发帖
  is_anonymous BOOLEAN DEFAULT FALSE,
  
  -- created_at 记录创建时间
  -- TIMESTAMPTZ 是带时区的时间戳类型
  -- DEFAULT NOW() 表示如果不指定，自动填入当前时间
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- updated_at 记录最后更新时间
  updated_at TIMESTAMPTZ DEFAULT NOW()
);


-- ============================================
-- 自动更新 updated_at 的触发器函数
-- ============================================
-- 
-- 🎯 这个函数的作用：
-- 每次更新数据时，自动把 updated_at 改成当前时间
-- 这样我们就不用每次手动设置了
-- 
-- 📝 解释：
-- CREATE OR REPLACE FUNCTION - 创建或替换一个函数
-- RETURNS TRIGGER - 这个函数用于触发器
-- $$ ... $$ - 函数体的边界标记
-- BEGIN ... END - 函数代码块
-- NEW - 代表即将被更新的新数据
-- RETURN NEW - 返回修改后的数据

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  -- 把新数据的 updated_at 字段设置为当前时间
  NEW.updated_at = NOW();
  -- 返回修改后的数据
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;  -- 使用 PL/pgSQL 语言（PostgreSQL 的存储过程语言）


-- ============================================
-- 为 profiles 表创建触发器
-- ============================================
-- 
-- 🎯 触发器的作用：
-- 当 profiles 表的数据被更新（UPDATE）时
-- 自动调用上面的 update_updated_at 函数
-- 
-- 📝 解释：
-- BEFORE UPDATE - 在更新之前执行
-- FOR EACH ROW - 对每一行数据都执行
-- EXECUTE FUNCTION - 执行指定的函数

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();


-- ============================================
-- 新用户注册时自动创建 profile
-- ============================================
-- 
-- 🎯 这个函数的作用：
-- 当用户通过 Supabase Auth 注册后
-- 自动在 profiles 表中创建一条对应的记录
-- 这样开发者不需要手动处理
-- 
-- 📝 NEW 变量说明：
-- NEW.id - 新注册用户的 ID
-- NEW.email - 新注册用户的邮箱
-- NEW.raw_user_meta_data - 注册时传入的额外信息（JSON格式）

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  -- INSERT INTO 向表中插入新数据
  -- public.profiles 指的是 public schema 下的 profiles 表
  INSERT INTO public.profiles (id, email, university)
  VALUES (
    NEW.id,                                              -- 用户 ID
    NEW.email,                                           -- 用户邮箱
    -- COALESCE 函数：如果第一个值是 NULL，就用第二个值
    -- 这里是从 meta_data 中取 university，如果没有就用 'Unknown'
    COALESCE(NEW.raw_user_meta_data->>'university', 'Unknown')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;  -- SECURITY DEFINER 表示以函数创建者的权限执行


-- 在 auth.users 表上创建触发器
-- 当新用户注册（INSERT）后，自动调用 handle_new_user 函数
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION handle_new_user();


-- ============================================
-- 第二部分：帖子表 (posts)
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 存储所有类型帖子的公共信息
-- 无论是租房、二手、拼车还是论坛帖子
-- 都会先在这个表创建一条基础记录
-- 然后在对应的详情表（如 rent_posts）创建额外信息
-- 
-- 📝 这种设计叫做"表继承"或"多态关联"
-- 好处是可以统一管理所有帖子，方便搜索和排序

CREATE TABLE posts (
  -- id 使用 UUID，gen_random_uuid() 自动生成随机 UUID
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- user_id 关联到发帖用户
  -- NOT NULL 表示必须有发布者
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  
  -- type 帖子类型，用 CHECK 限制只能是这几个值
  -- 这叫做"约束"（Constraint），防止存入错误的数据
  type TEXT NOT NULL CHECK (type IN ('rent', 'secondhand', 'ride', 'team', 'forum')),
  
  -- title 帖子标题，必填
  title TEXT NOT NULL,
  
  -- description 帖子描述，可选
  description TEXT,
  
  -- status 帖子状态
  -- active: 正常显示
  -- inactive: 用户主动下架
  -- deleted: 已删除（软删除，不是真的删掉）
  -- completed: 交易完成
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'deleted', 'completed')),
  
  -- is_anonymous 是否匿名发布
  is_anonymous BOOLEAN DEFAULT FALSE,
  
  -- view_count 浏览次数
  view_count INTEGER DEFAULT 0,
  
  -- 创建和更新时间
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- ============================================
  -- 全文搜索优化字段
  -- ============================================
  -- 
  -- 🎯 这是什么？
  -- TSVECTOR 是 PostgreSQL 的全文搜索向量类型
  -- 它会把标题和描述分词，方便快速搜索
  -- 
  -- 📝 GENERATED ALWAYS AS ... STORED
  -- 这是一个"计算列"，数据库会自动根据 title 和 description 生成
  -- 不需要我们手动维护
  -- 
  -- to_tsvector('english', ...) 使用英文分词
  -- COALESCE 处理 description 可能为 NULL 的情况
  search_tsv TSVECTOR GENERATED ALWAYS AS (
    to_tsvector('english', title || ' ' || COALESCE(description, ''))
  ) STORED
);


-- ============================================
-- 为 posts 表创建索引
-- ============================================
-- 
-- 🎯 索引是什么？
-- 想象一本书的目录，有了目录就能快速找到内容
-- 数据库索引也是类似的作用，加快查询速度
-- 
-- 📝 不同类型的索引：
-- GIN - 用于全文搜索，适合 TSVECTOR 类型
-- BTREE - 普通索引（默认），适合排序和等值查询

-- 全文搜索索引
CREATE INDEX posts_search_idx ON posts USING GIN (search_tsv);

-- 类型和状态的复合索引，加快按类型筛选的速度
CREATE INDEX posts_type_idx ON posts (type, status);

-- 用户索引，加快"查看我的帖子"的速度
CREATE INDEX posts_user_idx ON posts (user_id);

-- 创建时间索引（降序），加快"最新帖子"列表的速度
-- DESC 表示降序排列
CREATE INDEX posts_created_idx ON posts (created_at DESC);


-- 为 posts 表添加自动更新时间的触发器
CREATE TRIGGER posts_updated_at
  BEFORE UPDATE ON posts
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();


-- ============================================
-- 第三部分：帖子图片表 (post_images)
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 一个帖子可以有多张图片
-- 所以我们用单独的表来存储图片信息
-- 这叫做"一对多"关系（一个帖子对应多张图片）

CREATE TABLE post_images (
  -- 图片的唯一 ID
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- 关联到帖子，帖子删除时图片记录也删除
  post_id UUID REFERENCES posts(id) ON DELETE CASCADE NOT NULL,
  
  -- 图片的 URL 地址（存储在 Supabase Storage 中）
  url TEXT NOT NULL,
  
  -- 图片顺序，0 是第一张（通常作为封面）
  order_index INTEGER DEFAULT 0,
  
  -- 上传时间
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建索引，加快"获取某个帖子的所有图片"的查询速度
CREATE INDEX post_images_post_idx ON post_images (post_id);


-- ============================================
-- 第四部分：收藏表 (favorites)
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 记录用户收藏了哪些帖子
-- 这是一个"多对多"关系表
-- （一个用户可以收藏多个帖子，一个帖子可以被多人收藏）
-- 
-- 📝 复合主键：
-- 我们用 (user_id, post_id) 作为主键
-- 这意味着同一个用户不能重复收藏同一个帖子

CREATE TABLE favorites (
  -- 收藏者
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  
  -- 被收藏的帖子
  post_id UUID REFERENCES posts(id) ON DELETE CASCADE,
  
  -- 收藏时间
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- 复合主键：user_id 和 post_id 的组合必须唯一
  PRIMARY KEY (user_id, post_id)
);

-- 为两个外键分别创建索引
-- 这样无论是"查看某用户的收藏"还是"查看某帖子被谁收藏"都很快
CREATE INDEX favorites_user_idx ON favorites (user_id);
CREATE INDEX favorites_post_idx ON favorites (post_id);


-- ============================================
-- 第五部分：浏览历史表 (view_history)
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 记录用户看过哪些帖子
-- 可以用来做"最近浏览"功能

CREATE TABLE view_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- 浏览者
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  
  -- 被浏览的帖子
  post_id UUID REFERENCES posts(id) ON DELETE CASCADE,
  
  -- 浏览时间
  viewed_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- UNIQUE 约束：同一用户对同一帖子只保留一条记录
  -- 如果重复浏览，可以更新 viewed_at 时间
  UNIQUE(user_id, post_id)
);

-- 创建索引，方便查询某用户的浏览历史（按时间倒序）
CREATE INDEX view_history_user_idx ON view_history (user_id, viewed_at DESC);


-- ============================================
-- 🎉 完成！
-- ============================================
-- 
-- 执行完这个文件后，你的数据库就有了：
-- 1. profiles 表 - 存储用户信息
-- 2. posts 表 - 存储所有帖子的基础信息
-- 3. post_images 表 - 存储帖子图片
-- 4. favorites 表 - 存储用户收藏
-- 5. view_history 表 - 存储浏览历史
-- 
-- 以及必要的索引和触发器来保证性能和数据一致性
-- 
-- 下一步：执行 002_rent_posts.sql 创建租房详情表
